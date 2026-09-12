#!/usr/bin/env bash
set -Eeuo pipefail

# Oracle Cloud Shell one-click bootstrap for A1 scraper VMs.
# v2 fixes Cloud Shell config discovery (/etc/oci/config via OCI_CLI_CONFIG_FILE)
# and avoids relying on the hostname command.

TS="$(date +%Y%m%d_%H%M%S)"
REPORT="$HOME/oracle_a1_selfheal_${TS}.txt"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
exec > >(tee -a "$REPORT") 2>&1

node_name(){ uname -n 2>/dev/null || printf 'unknown'; }
need(){ command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing command: $1"; exit 1; }; }
for c in oci ssh scp ssh-keygen python3 awk sed grep curl; do need "$c"; done

echo "=== Oracle A1 one-click bootstrap v2 ==="
echo "time: $(date -Is)"
echo "shell-host: $(node_name)"

# Cloud Shell normally supplies these automatically.
OCI_CFG="${OCI_CLI_CONFIG_FILE:-}"
if [[ -z "$OCI_CFG" ]]; then
  if [[ -r /etc/oci/config ]]; then OCI_CFG=/etc/oci/config
  elif [[ -r "$HOME/.oci/config" ]]; then OCI_CFG="$HOME/.oci/config"
  fi
fi
PROFILE="${OCI_CLI_PROFILE:-DEFAULT}"

if [[ -z "$OCI_CFG" || ! -r "$OCI_CFG" ]]; then
  echo "ERROR: OCI config not found. OCI_CLI_CONFIG_FILE=${OCI_CLI_CONFIG_FILE:-<unset>}"
  exit 2
fi

echo "OCI config: $OCI_CFG"
echo "OCI profile: $PROFILE"

TENANCY="$(python3 - "$OCI_CFG" "$PROFILE" <<'PY'
import configparser,sys
p,prof=sys.argv[1:3]
c=configparser.RawConfigParser()
c.read(p)
for sec in (prof,'DEFAULT'):
    if sec=='DEFAULT':
        v=c.defaults().get('tenancy')
    elif c.has_section(sec):
        v=c.get(sec,'tenancy',fallback=None)
    else:
        v=None
    if v:
        print(v.strip()); raise SystemExit
for sec in c.sections():
    v=c.get(sec,'tenancy',fallback=None)
    if v:
        print(v.strip()); raise SystemExit
PY
)"

if [[ -z "$TENANCY" ]]; then
  echo "ERROR: tenancy OCID not found in $OCI_CFG (profile $PROFILE)"
  echo "Cloud Shell should normally expose /etc/oci/config."
  exit 3
fi

echo "[1/8] OCI session check"
oci iam region-subscription list --tenancy-id "$TENANCY" --output table >/dev/null

echo "[2/8] Discovering running A1 instances"
COMP="$TMP/compartments.txt"
{
  echo "$TENANCY"
  oci iam compartment list --compartment-id "$TENANCY" --compartment-id-in-subtree true --access-level ACCESSIBLE --all --output json 2>/dev/null |
    python3 -c 'import json,sys; d=json.load(sys.stdin).get("data",[]); [print(x["id"]) for x in d if x.get("lifecycle-state")=="ACTIVE"]'
} | awk 'NF' | sort -u > "$COMP"

A1="$TMP/a1.tsv"; : > "$A1"
while IFS= read -r C; do
  oci compute instance list --compartment-id "$C" --all --output json 2>/dev/null |
    python3 - "$C" <<'PY' >> "$A1" || true
import json,sys
comp=sys.argv[1]; d=json.load(sys.stdin).get('data',[])
for x in d:
    if x.get('lifecycle-state')=='RUNNING' and x.get('shape')=='VM.Standard.A1.Flex':
        print('\t'.join([x['id'],x.get('display-name',''),comp]))
PY
done < "$COMP"
sort -u "$A1" -o "$A1"
[[ -s "$A1" ]] || { echo "ERROR: no RUNNING VM.Standard.A1.Flex instance found"; exit 4; }

echo "A1 instances:"
awk -F'\t' '{print "  - "$2}' "$A1"

echo "[3/8] Resolving public IPs"
HOSTS="$TMP/hosts.tsv"; : > "$HOSTS"
while IFS=$'\t' read -r IID NAME CID; do
  V="$(oci compute instance list-vnics --instance-id "$IID" --output json 2>/dev/null || true)"
  IP="$(printf '%s' "$V" | python3 -c 'import json,sys; d=json.load(sys.stdin).get("data",[]); print(next((x.get("public-ip") for x in d if x.get("public-ip")),""))' 2>/dev/null || true)"
  [[ -n "$IP" ]] && printf '%s\t%s\t%s\t%s\n' "$NAME" "$IID" "$CID" "$IP" >> "$HOSTS"
done < "$A1"
[[ -s "$HOSTS" ]] || { echo "ERROR: no public IP found for A1 instances"; exit 5; }
awk -F'\t' '{print "  "$1" -> "$4}' "$HOSTS"

echo "[4/8] Discovering SSH keys"
mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
KEYS="$TMP/keys.txt"; : > "$KEYS"
for f in "$HOME/.ssh"/*; do
  [[ -f "$f" ]] || continue
  case "$f" in *.pub|*known_hosts*|*config|*authorized_keys*) continue;; esac
  ssh-keygen -y -f "$f" >/dev/null 2>&1 && echo "$f" >> "$KEYS"
done

# Keep a dedicated future key available. It only works immediately if already authorized.
DED="$HOME/.ssh/a1_selfheal_ed25519"
if [[ ! -f "$DED" ]]; then ssh-keygen -q -t ed25519 -N '' -f "$DED" -C 'cloudshell-a1-selfheal' </dev/null; fi
grep -Fxq "$DED" "$KEYS" 2>/dev/null || echo "$DED" >> "$KEYS"

REACH="$TMP/reachable.tsv"; : > "$REACH"
echo "[5/8] Testing SSH access"
while IFS=$'\t' read -r NAME IID CID IP; do
  ok=0
  for USER in ubuntu opc; do
    while IFS= read -r KEY; do
      if ssh -i "$KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 "$USER@$IP" 'printf ok' 2>/dev/null | grep -qx ok; then
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$NAME" "$IID" "$CID" "$IP" "$USER" "$KEY" >> "$REACH"
        echo "  OK $NAME ($IP) user=$USER key=$(basename "$KEY")"
        ok=1; break 2
      fi
    done < "$KEYS"
  done
  [[ $ok -eq 1 ]] || echo "  FAIL $NAME ($IP): no existing authorized Cloud Shell key"
done < "$HOSTS"

if [[ ! -s "$REACH" ]]; then
  echo "ERROR: A1 VMs were found, but Cloud Shell has no key currently authorized on them."
  echo "Generated public key for recovery:"
  cat "$DED.pub"
  echo "Add this public key to the VM once via OCI recovery/console, then rerun this same one-liner."
  exit 6
fi

# Assign primary/secondary without requiring the user to know names.
ROLES="$TMP/roles.tsv"
python3 - "$REACH" "$ROLES" <<'PY'
import sys
rows=[x.rstrip('\n').split('\t') for x in open(sys.argv[1],encoding='utf-8') if x.strip()]
def pscore(r):
    n=r[0].lower(); return (0 if any(k in n for k in ('primary','main','a1hunter')) else 1,n)
def sscore(r):
    n=r[0].lower(); return (0 if any(k in n for k in ('secondary','second','backup')) else 1,n)
p=min(rows,key=pscore)
rem=[r for r in rows if r!=p]
with open(sys.argv[2],'w',encoding='utf-8') as f:
    f.write('primary\t'+'\t'.join(p)+'\n')
    if rem: f.write('secondary\t'+'\t'.join(min(rem,key=sscore))+'\n')
PY

echo "Roles:"
awk -F'\t' '{print "  "$1" = "$2" ("$5")"}' "$ROLES"

echo "[6/8] Writing SSH aliases"
CFG="$HOME/.ssh/config"; touch "$CFG"; chmod 600 "$CFG"
python3 - "$CFG" <<'PY'
import os,re,sys
p=sys.argv[1]; s=open(p,encoding='utf-8').read() if os.path.exists(p) else ''
s=re.sub(r'\n?# BEGIN A1 SELFHEAL.*?# END A1 SELFHEAL\n?','\n',s,flags=re.S)
open(p,'w',encoding='utf-8').write(s.rstrip()+('\n' if s.strip() else ''))
PY
{
  echo '# BEGIN A1 SELFHEAL'
  while IFS=$'\t' read -r ROLE NAME IID CID IP USER KEY; do
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
  done < "$ROLES"
  echo '# END A1 SELFHEAL'
} >> "$CFG"

# Remote self-heal installer.
INSTALL="$TMP/install.sh"
cat > "$INSTALL" <<'REMOTE'
#!/usr/bin/env bash
set -Eeuo pipefail
ROLE="${1:-unknown}"
SERVICE=dc-scraper.service
LOG=/var/log/dc-scraper-health
STATE=/var/lib/dc-scraper-health
mkdir -p "$LOG" "$STATE"
echo "$ROLE" > "$STATE/role"
cat >/usr/local/sbin/dc-scraper-healthcheck <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
SERVICE=dc-scraper.service
LOG=/var/log/dc-scraper-health
STATE=/var/lib/dc-scraper-health
ROLE="$(cat "$STATE/role" 2>/dev/null || echo unknown)"
mkdir -p "$LOG" "$STATE"
TS="$(date +%Y%m%d_%H%M%S)"; OUT="$LOG/${ROLE}_${TS}.txt"; LATEST="$LOG/${ROLE}_latest.txt"
FAIL="$(cat "$STATE/fail_count" 2>/dev/null || echo 0)"
LAST_REBOOT="$(cat "$STATE/last_reboot" 2>/dev/null || echo 0)"; NOW="$(date +%s)"
diag(){ { date -Is; uname -a; uptime; free -h; df -h; systemctl status "$SERVICE" --no-pager -l || true; systemctl show "$SERVICE" -p ActiveState -p SubState -p MainPID -p NRestarts -p CPUUsageNSec || true; ps -eo pid,ppid,%cpu,%mem,etime,stat,cmd --sort=-%cpu | head -60; journalctl -u "$SERVICE" --since '-90 min' --no-pager -n 1200 || true; dmesg -T 2>&1 | grep -Ei 'oom|out of memory|killed process|segfault' | tail -100 || true; } >"$OUT" 2>&1; cp -f "$OUT" "$LATEST"; }
find "$LOG" -type f -name '*.txt' -mtime +14 -delete 2>/dev/null || true
if ! systemctl is-active --quiet "$SERVICE"; then
  diag; systemctl restart "$SERVICE" || true; sleep 20
  if systemctl is-active --quiet "$SERVICE"; then echo 0 > "$STATE/fail_count"; exit 0; fi
  FAIL=$((FAIL+1)); echo "$FAIL" > "$STATE/fail_count"
else
  PID="$(systemctl show "$SERVICE" -p MainPID --value 2>/dev/null || echo 0)"
  C1="$(systemctl show "$SERVICE" -p CPUUsageNSec --value 2>/dev/null || echo 0)"; sleep 5
  C2="$(systemctl show "$SERVICE" -p CPUUsageNSec --value 2>/dev/null || echo 0)"
  if [[ "$PID" != 0 && "$C1" != "$C2" ]]; then echo 0 > "$STATE/fail_count"; exit 0; fi
  if ! curl -fsSI --connect-timeout 8 --max-time 15 -A 'Mozilla/5.0' 'https://gall.dcinside.com/mgallery/board/lists/?id=lawschool' >/dev/null 2>&1; then diag; exit 0; fi
  diag; systemctl kill --kill-who=all "$SERVICE" 2>/dev/null || true; sleep 3; systemctl restart "$SERVICE" || true; sleep 20
  if systemctl is-active --quiet "$SERVICE"; then echo 0 > "$STATE/fail_count"; exit 0; fi
  FAIL=$((FAIL+1)); echo "$FAIL" > "$STATE/fail_count"
fi
if (( FAIL >= 3 && NOW - LAST_REBOOT >= 21600 )); then
  diag; echo "$NOW" > "$STATE/last_reboot"; echo 0 > "$STATE/fail_count"; systemctl reboot
fi
EOF
chmod 0755 /usr/local/sbin/dc-scraper-healthcheck
mkdir -p /etc/systemd/system/dc-scraper.service.d
cat >/etc/systemd/system/dc-scraper.service.d/90-selfheal.conf <<'EOF'
[Service]
Restart=always
RestartSec=15s
TimeoutStopSec=30s
EOF
cat >/etc/systemd/system/dc-scraper-healthcheck.service <<'EOF'
[Unit]
Description=DC scraper self-heal watchdog
After=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/dc-scraper-healthcheck
EOF
cat >/etc/systemd/system/dc-scraper-healthcheck.timer <<'EOF'
[Unit]
Description=DC scraper watchdog every 10 minutes
[Timer]
OnBootSec=5min
OnUnitActiveSec=10min
RandomizedDelaySec=30s
Persistent=true
[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now dc-scraper-healthcheck.timer
systemctl restart "$SERVICE" || true
sleep 5
systemctl start dc-scraper-healthcheck.service || true
echo "ROLE=$ROLE scraper=$(systemctl is-active "$SERVICE" 2>/dev/null || true) watchdog=$(systemctl is-active dc-scraper-healthcheck.timer 2>/dev/null || true)"
REMOTE
chmod +x "$INSTALL"

echo "[7/8] Installing on reachable roles"
while IFS=$'\t' read -r ROLE NAME IID CID IP USER KEY; do
  ALIAS="a1-$ROLE"
  echo "--- $ALIAS / $NAME ---"
  scp -q "$INSTALL" "$ALIAS:/tmp/a1-selfheal-install.sh"
  ssh "$ALIAS" "sudo bash /tmp/a1-selfheal-install.sh '$ROLE'"
done < "$ROLES"

echo "[8/8] Verifying"
while IFS=$'\t' read -r ROLE NAME IID CID IP USER KEY; do
  ALIAS="a1-$ROLE"
  echo "--- $ALIAS ---"
  ssh "$ALIAS" 'printf "host="; uname -n; systemctl is-active dc-scraper.service || true; systemctl is-active dc-scraper-healthcheck.timer || true; sudo ls -lh /var/log/dc-scraper-health/*latest.txt 2>/dev/null || true'
done < "$ROLES"

echo
echo "DONE"
echo "SSH: ssh a1-primary"
if grep -q '^Host a1-secondary$' "$CFG"; then echo "SSH: ssh a1-secondary"; fi
echo "Report: $REPORT"
