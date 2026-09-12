#!/usr/bin/env bash
set -Eeuo pipefail

# One-click Oracle Cloud Shell bootstrap for A1 scraper VMs.
# - discovers running VM.Standard.A1.Flex instances across accessible compartments
# - discovers public IPs
# - tries existing local SSH keys with ubuntu/opc users
# - writes ~/.ssh/config aliases a1-primary / a1-secondary
# - installs a systemd watchdog/self-heal policy on each reachable VM
# - writes a consolidated report in Cloud Shell
# Safe defaults: no secrets are printed, no scraper data is deleted.

TS="$(date +%Y%m%d_%H%M%S)"
REPORT="$HOME/oracle_a1_selfheal_${TS}.txt"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

exec > >(tee -a "$REPORT") 2>&1

echo "=== Oracle A1 one-click bootstrap ==="
echo "time: $(date -Is)"
echo "host: $(hostname)"

a_need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing command: $1"; exit 1; }; }
a_need oci
a_need ssh
a_need awk
a_need sed
a_need grep

# Validate OCI CLI session.
echo "[1/8] Checking OCI CLI session..."
TENANCY="$(awk -F= '$1=="tenancy"{print $2; exit}' "$HOME/.oci/config" 2>/dev/null || true)"
if [[ -z "$TENANCY" ]]; then
  echo "ERROR: tenancy OCID not found in ~/.oci/config"
  exit 2
fi
oci iam region-subscription list --tenancy-id "$TENANCY" --output table >/dev/null

echo "[2/8] Discovering accessible compartments..."
COMP_FILE="$TMPDIR/compartments.txt"
{
  printf '%s\n' "$TENANCY"
  oci iam compartment list \
    --compartment-id "$TENANCY" \
    --compartment-id-in-subtree true \
    --access-level ACCESSIBLE \
    --all \
    --query 'data[?"lifecycle-state"==`ACTIVE`].id' \
    --raw-output 2>/dev/null | tr -d '[]," ' | tr ',' '\n'
} | awk 'NF' | sort -u > "$COMP_FILE"

A1_FILE="$TMPDIR/a1.tsv"
: > "$A1_FILE"
while IFS= read -r COMP; do
  [[ -z "$COMP" ]] && continue
  oci compute instance list \
    --compartment-id "$COMP" --all \
    --query 'data[?"lifecycle-state"==`RUNNING` && shape==`VM.Standard.A1.Flex`].[id,"display-name","availability-domain"]' \
    --output json 2>/dev/null |
  python3 -c 'import json,sys; d=json.load(sys.stdin); [print("\t".join(map(str,x))) for x in d]' 2>/dev/null >> "$A1_FILE" || true
done < "$COMP_FILE"

if [[ ! -s "$A1_FILE" ]]; then
  echo "ERROR: no running VM.Standard.A1.Flex instance found."
  exit 3
fi

sort -u "$A1_FILE" -o "$A1_FILE"
echo "Found A1 instances:"
awk -F'\t' '{printf "  - %s\n", $2}' "$A1_FILE"

echo "[3/8] Resolving public IPs..."
HOSTS_FILE="$TMPDIR/hosts.tsv"
: > "$HOSTS_FILE"
while IFS=$'\t' read -r IID NAME AD; do
  # Instance list-vnics resolves compartment internally.
  VNIC_JSON="$(oci compute instance list-vnics --instance-id "$IID" --output json 2>/dev/null || true)"
  IP="$(printf '%s' "$VNIC_JSON" | python3 -c 'import json,sys; d=json.load(sys.stdin).get("data",[]); print(next((x.get("public-ip") for x in d if x.get("public-ip")), ""))' 2>/dev/null || true)"
  [[ -n "$IP" ]] && printf '%s\t%s\t%s\n' "$NAME" "$IID" "$IP" >> "$HOSTS_FILE"
done < "$A1_FILE"

if [[ ! -s "$HOSTS_FILE" ]]; then
  echo "ERROR: A1 instances found but none has a public IPv4 address."
  echo "Use OCI Bastion/private networking, or assign a public IP first."
  exit 4
fi

cat "$HOSTS_FILE" | awk -F'\t' '{printf "  %s -> %s\n",$1,$3}'

echo "[4/8] Discovering usable SSH private keys..."
KEY_FILE="$TMPDIR/keys.txt"
: > "$KEY_FILE"
for f in "$HOME/.ssh"/*; do
  [[ -f "$f" ]] || continue
  case "$f" in
    *.pub|*known_hosts*|*config|*authorized_keys*) continue;;
  esac
  if ssh-keygen -y -f "$f" >/dev/null 2>&1; then
    printf '%s\n' "$f" >> "$KEY_FILE"
  fi
done

if [[ ! -s "$KEY_FILE" ]]; then
  echo "ERROR: no usable private SSH key found under ~/.ssh"
  echo "The script cannot safely invent access to an existing VM without an authorized key."
  echo "Recover/add SSH access in OCI first, then rerun this same command."
  exit 5
fi

while IFS= read -r k; do echo "  key candidate: $k"; done < "$KEY_FILE"

echo "[5/8] Testing SSH access..."
REACHABLE="$TMPDIR/reachable.tsv"
: > "$REACHABLE"
while IFS=$'\t' read -r NAME IID IP; do
  FOUND=0
  for USER in ubuntu opc; do
    while IFS= read -r KEY; do
      if ssh -i "$KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=7 \
          "$USER@$IP" 'echo ok' 2>/dev/null | grep -qx ok; then
        printf '%s\t%s\t%s\t%s\t%s\n' "$NAME" "$IID" "$IP" "$USER" "$KEY" >> "$REACHABLE"
        echo "  OK: $NAME as $USER via $(basename "$KEY")"
        FOUND=1
        break 2
      fi
    done < "$KEY_FILE"
  done
  [[ "$FOUND" == 1 ]] || echo "  FAIL: no working SSH key/user for $NAME ($IP)"
done < "$HOSTS_FILE"

if [[ ! -s "$REACHABLE" ]]; then
  echo "ERROR: A1 instances exist, but none is SSH-reachable with Cloud Shell keys."
  exit 6
fi

# Rank aliases. Prefer names containing primary/main and secondary/backup; otherwise deterministic order.
python3 - "$REACHABLE" "$TMPDIR/roles.tsv" <<'PY'
import sys
rows=[]
for line in open(sys.argv[1], encoding='utf-8'):
    p=line.rstrip('\n').split('\t')
    if len(p)>=5: rows.append(p)
def score(name, role):
    n=name.lower()
    if role=='primary':
        return (0 if ('primary' in n or 'main' in n) else 1, n)
    return (0 if ('secondary' in n or 'backup' in n or 'second' in n) else 1, n)
primary=min(rows, key=lambda r: score(r[0],'primary'))
remaining=[r for r in rows if r is not primary]
secondary=min(remaining, key=lambda r: score(r[0],'secondary')) if remaining else None
with open(sys.argv[2],'w',encoding='utf-8') as f:
    f.write('primary\t'+'\t'.join(primary)+'\n')
    if secondary: f.write('secondary\t'+'\t'.join(secondary)+'\n')
PY

ROLE_FILE="$TMPDIR/roles.tsv"
echo "Roles:"
awk -F'\t' '{printf "  %s = %s (%s)\n",$1,$2,$4}' "$ROLE_FILE"

echo "[6/8] Writing ~/.ssh/config aliases..."
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
CONFIG="$HOME/.ssh/config"
touch "$CONFIG"
chmod 600 "$CONFIG"
# Remove previous managed block.
python3 - "$CONFIG" <<'PY'
import sys,re
p=sys.argv[1]
s=open(p,encoding='utf-8').read() if __import__('os').path.exists(p) else ''
s=re.sub(r'\n?# BEGIN CHATGPT A1 SELFHEAL.*?# END CHATGPT A1 SELFHEAL\n?', '\n', s, flags=re.S)
open(p,'w',encoding='utf-8').write(s.rstrip()+('\n' if s.strip() else ''))
PY
{
  echo '# BEGIN CHATGPT A1 SELFHEAL'
  while IFS=$'\t' read -r ROLE NAME IID IP USER KEY; do
    cat <<EOF
Host a1-$ROLE
    HostName $IP
    User $USER
    IdentityFile $KEY
    IdentitiesOnly yes
    ServerAliveInterval 30
    ServerAliveCountMax 3
    StrictHostKeyChecking accept-new
EOF
  done < "$ROLE_FILE"
  echo '# END CHATGPT A1 SELFHEAL'
} >> "$CONFIG"

cat > "$TMPDIR/install_remote.sh" <<'REMOTE'
#!/usr/bin/env bash
set -Eeuo pipefail
ROLE="${1:-unknown}"
SERVICE="dc-scraper.service"
LOG_DIR="/var/log/dc-scraper-health"
STATE_DIR="/var/lib/dc-scraper-health"
SCRIPT="/usr/local/sbin/dc-scraper-healthcheck"
mkdir -p "$LOG_DIR" "$STATE_DIR"

cat > "$SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
SERVICE="dc-scraper.service"
LOG_DIR="/var/log/dc-scraper-health"
STATE_DIR="/var/lib/dc-scraper-health"
ROLE="$(cat "$STATE_DIR/role" 2>/dev/null || echo unknown)"
mkdir -p "$LOG_DIR" "$STATE_DIR"
TS="$(date +%Y%m%d_%H%M%S)"
NOW="$(date +%s)"
OUT="$LOG_DIR/${ROLE}_$(hostname)_$TS.txt"
LATEST="$LOG_DIR/${ROLE}_latest.txt"
FAILFILE="$STATE_DIR/fail_count"
REBOOTFILE="$STATE_DIR/last_reboot_epoch"
FAILS="$(cat "$FAILFILE" 2>/dev/null || echo 0)"
LAST_REBOOT="$(cat "$REBOOTFILE" 2>/dev/null || echo 0)"
log(){ echo "[$(date -Is)] $*" | tee -a "$OUT"; }
diag(){
  {
    echo "role=$ROLE"; date -Is; hostnamectl 2>&1 || true; uptime; free -h; df -h;
    echo '=== service ==='; systemctl status "$SERVICE" --no-pager -l 2>&1 || true;
    echo '=== properties ==='; systemctl show "$SERVICE" -p ActiveState -p SubState -p Result -p MainPID -p ExecMainStatus -p NRestarts -p CPUUsageNSec 2>&1 || true;
    echo '=== processes ==='; ps -eo pid,ppid,user,%cpu,%mem,etime,stat,cmd --sort=-%cpu | head -50;
    echo '=== journal ==='; journalctl -u "$SERVICE" --since '-60 min' --no-pager -n 1000 2>&1 || true;
    echo '=== oom ==='; dmesg -T 2>&1 | grep -Ei 'oom|out of memory|killed process|segfault' | tail -100 || true;
    echo '=== dcinside ==='; curl -I -L --connect-timeout 8 --max-time 15 -A 'Mozilla/5.0' 'https://gall.dcinside.com/mgallery/board/lists/?id=lawschool' 2>&1 | head -50 || true;
  } >> "$OUT" 2>&1
  cp -f "$OUT" "$LATEST"
}

# Keep 14 days of diagnostics.
find "$LOG_DIR" -type f -name '*.txt' -mtime +14 -delete 2>/dev/null || true

if ! systemctl is-active --quiet "$SERVICE"; then
  log "service inactive -> diagnose and restart"
  diag
  systemctl restart "$SERVICE" || true
  sleep 20
  if systemctl is-active --quiet "$SERVICE"; then echo 0 > "$FAILFILE"; log 'recovered'; exit 0; fi
  FAILS=$((FAILS+1)); echo "$FAILS" > "$FAILFILE"
else
  PID="$(systemctl show "$SERVICE" -p MainPID --value 2>/dev/null || echo 0)"
  CPU1="$(systemctl show "$SERVICE" -p CPUUsageNSec --value 2>/dev/null || echo 0)"
  J1="$(journalctl -u "$SERVICE" --since '-30 min' --no-pager -n 1 2>/dev/null | wc -l)"
  sleep 3
  CPU2="$(systemctl show "$SERVICE" -p CPUUsageNSec --value 2>/dev/null || echo 0)"
  # Healthy if CPU is moving or there has been recent journal activity.
  if [[ "$PID" != 0 && ( "$CPU2" != "$CPU1" || "$J1" -gt 0 ) ]]; then
    echo 0 > "$FAILFILE"
    exit 0
  fi
  # Avoid restart if DCInside itself is unavailable.
  if ! curl -fsS -I --connect-timeout 8 --max-time 15 -A 'Mozilla/5.0' 'https://gall.dcinside.com/mgallery/board/lists/?id=lawschool' >/dev/null 2>&1; then
    log 'possible external/DCInside outage; keeping service untouched'
    diag
    exit 0
  fi
  log 'suspected hang -> diagnose, kill service cgroup, restart'
  diag
  systemctl kill --kill-who=all "$SERVICE" 2>/dev/null || true
  sleep 3
  systemctl restart "$SERVICE" || true
  sleep 20
  if systemctl is-active --quiet "$SERVICE"; then
    FAILS=$((FAILS+1)); echo "$FAILS" > "$FAILFILE"
  else
    FAILS=$((FAILS+1)); echo "$FAILS" > "$FAILFILE"
  fi
fi

# Escalation: three failed recoveries, at most one reboot per 6h.
if (( FAILS >= 3 )) && (( NOW - LAST_REBOOT >= 21600 )); then
  log "repeated recovery failures ($FAILS) -> controlled reboot"
  diag
  echo "$NOW" > "$REBOOTFILE"
  echo 0 > "$FAILFILE"
  systemctl reboot
fi
EOF
chmod 0755 "$SCRIPT"
echo "$ROLE" > "$STATE_DIR/role"

cat > /etc/systemd/system/dc-scraper-healthcheck.service <<EOF
[Unit]
Description=DC Scraper automatic health diagnosis and self-heal
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$SCRIPT
EOF

cat > /etc/systemd/system/dc-scraper-healthcheck.timer <<'EOF'
[Unit]
Description=Run DC Scraper healthcheck every 10 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=10min
RandomizedDelaySec=30s
Persistent=true

[Install]
WantedBy=timers.target
EOF

# Ensure scraper process itself auto-recovers from a real crash.
mkdir -p "/etc/systemd/system/$SERVICE.d"
cat > "/etc/systemd/system/$SERVICE.d/90-selfheal.conf" <<'EOF'
[Service]
Restart=always
RestartSec=15s
TimeoutStopSec=30s
EOF

systemctl daemon-reload
systemctl enable --now dc-scraper-healthcheck.timer
systemctl restart "$SERVICE"
sleep 5
systemctl start dc-scraper-healthcheck.service || true

echo "=== INSTALLED role=$ROLE ==="
systemctl is-active "$SERVICE" || true
systemctl is-active dc-scraper-healthcheck.timer || true
systemctl list-timers dc-scraper-healthcheck.timer --no-pager || true
REMOTE
chmod +x "$TMPDIR/install_remote.sh"

echo "[7/8] Installing self-heal on discovered roles..."
while IFS=$'\t' read -r ROLE NAME IID IP USER KEY; do
  echo "--- $ROLE / $NAME / $IP ---"
  scp -i "$KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "$TMPDIR/install_remote.sh" "$USER@$IP:/tmp/install_dc_selfheal.sh"
  ssh -i "$KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "$USER@$IP" \
    "sudo bash /tmp/install_dc_selfheal.sh '$ROLE' && rm -f /tmp/install_dc_selfheal.sh"
done < "$ROLE_FILE"

echo "[8/8] Verifying aliases and services..."
while IFS=$'\t' read -r ROLE NAME IID IP USER KEY; do
  echo "=== a1-$ROLE ==="
  ssh -o BatchMode=yes -o ConnectTimeout=10 "a1-$ROLE" \
    "hostname; echo role=$ROLE; systemctl is-active dc-scraper.service || true; systemctl is-active dc-scraper-healthcheck.timer || true; sudo systemctl status dc-scraper.service --no-pager -l | head -25" || true
done < "$ROLE_FILE"

echo
echo "DONE"
echo "SSH aliases created:"
awk -F'\t' '{print "  ssh a1-"$1}' "$ROLE_FILE"
echo "Report: $REPORT"
echo "Future diagnostics on a VM: sudo cat /var/log/dc-scraper-health/${ROLE:-primary}_latest.txt"
