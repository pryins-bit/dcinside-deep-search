#!/usr/bin/env bash
set -Eeuo pipefail
TS="$(date +%Y%m%d_%H%M%S)"
REPORT="$HOME/oracle_a1_selfheal_${TS}.txt"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
exec > >(tee -a "$REPORT") 2>&1

say(){ printf '%s\n' "$*"; }
need(){ command -v "$1" >/dev/null 2>&1 || { say "ERROR: missing command: $1"; exit 1; }; }
need oci; need ssh; need scp; need ssh-keygen; need python3; need curl

say '=== Oracle A1 one-click v3 ==='
say "time: $(date -Is)"
say "shell-host: $(uname -n 2>/dev/null || echo cloud-shell)"

# Cloud Shell normally exports these; fall back safely.
CONFIG="${OCI_CLI_CONFIG_FILE:-}"
[[ -n "$CONFIG" && -f "$CONFIG" ]] || { [[ -f /etc/oci/config ]] && CONFIG=/etc/oci/config || CONFIG="$HOME/.oci/config"; }
PROFILE="${OCI_CLI_PROFILE:-DEFAULT}"
say "OCI config: $CONFIG"
say "OCI profile: $PROFILE"
[[ -f "$CONFIG" ]] || { say 'ERROR: OCI config not found'; exit 2; }

TENANCY="$(python3 - "$CONFIG" "$PROFILE" <<'PY'
import configparser,sys
p,profile=sys.argv[1:3]
c=configparser.ConfigParser(interpolation=None)
c.read(p)
sec=profile if profile in c else ('DEFAULT' if 'DEFAULT' in c else None)
if sec=='DEFAULT': print(c.defaults().get('tenancy',''))
elif sec: print(c[sec].get('tenancy',''))
else: print('')
PY
)"
[[ -n "$TENANCY" ]] || { say 'ERROR: tenancy OCID not found in active OCI profile'; exit 3; }

say '[1/8] OCI session check'
oci iam region-subscription list --tenancy-id "$TENANCY" --output json >"$TMP/regions.json" 2>"$TMP/regions.err" || {
  cat "$TMP/regions.err"; say 'ERROR: OCI CLI authentication failed'; exit 4; }
python3 -m json.tool "$TMP/regions.json" >/dev/null 2>&1 || { say 'ERROR: OCI returned invalid JSON'; head -20 "$TMP/regions.json"; exit 5; }

say '[2/8] Discovering accessible compartments and running A1 instances'
printf '%s\n' "$TENANCY" > "$TMP/comps.txt"
if oci iam compartment list --compartment-id "$TENANCY" --compartment-id-in-subtree true --access-level ACCESSIBLE --all --output json >"$TMP/comps.json" 2>"$TMP/comps.err"; then
  python3 - "$TMP/comps.json" >> "$TMP/comps.txt" <<'PY'
import json,sys
try:d=json.load(open(sys.argv[1]))
except Exception: d={}
for x in d.get('data',[]):
    if x.get('lifecycle-state')=='ACTIVE' and x.get('id'): print(x['id'])
PY
else
  say 'WARN: compartment listing failed; continuing with tenancy root.'
  sed 's/^/  /' "$TMP/comps.err" | head -20
fi
sort -u "$TMP/comps.txt" -o "$TMP/comps.txt"
: > "$TMP/a1.tsv"
while IFS= read -r COMP; do
  [[ -n "$COMP" ]] || continue
  if oci compute instance list --compartment-id "$COMP" --all --output json >"$TMP/inst.json" 2>"$TMP/inst.err"; then
    if python3 -m json.tool "$TMP/inst.json" >/dev/null 2>&1; then
      python3 - "$TMP/inst.json" >> "$TMP/a1.tsv" <<'PY'
import json,sys
for x in json.load(open(sys.argv[1])).get('data',[]):
    if x.get('lifecycle-state')=='RUNNING' and x.get('shape')=='VM.Standard.A1.Flex':
        print('\t'.join([x.get('display-name','unnamed'),x.get('id',''),x.get('availability-domain','')]))
PY
    fi
  else
    say "  skip compartment (no access/transient error): ${COMP:0:28}..."
  fi
done < "$TMP/comps.txt"
sort -u "$TMP/a1.tsv" -o "$TMP/a1.tsv"
[[ -s "$TMP/a1.tsv" ]] || { say 'ERROR: no running VM.Standard.A1.Flex found'; exit 6; }
say 'A1 instances:'; awk -F'\t' '{print "  - "$1}' "$TMP/a1.tsv"

say '[3/8] Resolving public IPv4 addresses'
: > "$TMP/hosts.tsv"
while IFS=$'\t' read -r NAME IID AD; do
  if oci compute instance list-vnics --instance-id "$IID" --output json >"$TMP/vnic.json" 2>"$TMP/vnic.err"; then
    IP="$(python3 - "$TMP/vnic.json" <<'PY'
import json,sys
try:d=json.load(open(sys.argv[1])).get('data',[])
except Exception:d=[]
print(next((x.get('public-ip') for x in d if x.get('public-ip')),''))
PY
)"
    [[ -n "$IP" ]] && printf '%s\t%s\t%s\n' "$NAME" "$IID" "$IP" >> "$TMP/hosts.tsv"
  fi
done < "$TMP/a1.tsv"
[[ -s "$TMP/hosts.tsv" ]] || { say 'ERROR: A1 VMs found, but no public IPv4 was resolved'; exit 7; }
awk -F'\t' '{print "  "$1" -> "$3}' "$TMP/hosts.tsv"

say '[4/8] Finding usable SSH keys'
mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
: > "$TMP/keys.txt"
for f in "$HOME/.ssh"/*; do
  [[ -f "$f" ]] || continue
  case "$f" in *.pub|*known_hosts*|*config|*authorized_keys*) continue;; esac
  ssh-keygen -y -f "$f" >/dev/null 2>&1 && printf '%s\n' "$f" >> "$TMP/keys.txt"
done
if [[ ! -s "$TMP/keys.txt" ]]; then
  KEY="$HOME/.ssh/a1_selfheal_ed25519"
  [[ -f "$KEY" ]] || ssh-keygen -q -t ed25519 -N '' -f "$KEY" -C 'cloudshell-a1-selfheal'
  printf '%s\n' "$KEY" > "$TMP/keys.txt"
  say "Generated SSH key: $KEY"
  say 'NOTE: if this new key is not already authorized on the VM, the script will report that SSH recovery is required.'
fi

say '[5/8] Testing SSH access automatically'
: > "$TMP/reachable.tsv"
while IFS=$'\t' read -r NAME IID IP; do
  FOUND=0
  for USER in ubuntu opc; do
    while IFS= read -r KEY; do
      if ssh -i "$KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 "$USER@$IP" 'printf ok' 2>/dev/null | grep -qx ok; then
        printf '%s\t%s\t%s\t%s\t%s\n' "$NAME" "$IID" "$IP" "$USER" "$KEY" >> "$TMP/reachable.tsv"
        say "  OK $NAME -> $USER@$IP via $(basename "$KEY")"
        FOUND=1; break 2
      fi
    done < "$TMP/keys.txt"
  done
  [[ "$FOUND" == 1 ]] || say "  SSH NOT REACHABLE: $NAME ($IP)"
done < "$TMP/hosts.tsv"

if [[ ! -s "$TMP/reachable.tsv" ]]; then
  say 'ERROR: no A1 VM is reachable with keys currently available in Cloud Shell.'
  say 'Generated/current public keys:'
  while IFS= read -r KEY; do ssh-keygen -y -f "$KEY" 2>/dev/null | sed 's/^/  /'; done < "$TMP/keys.txt"
  say "REPORT=$REPORT"
  exit 8
fi

# Determine roles. Prefer semantic names, then inspect service presence, then deterministic order.
python3 - "$TMP/reachable.tsv" "$TMP/roles.tsv" <<'PY'
import sys
rows=[x.rstrip('\n').split('\t') for x in open(sys.argv[1]) if x.strip()]
def pscore(r):
 n=r[0].lower(); return (0 if any(k in n for k in ('primary','main','a1hunter')) else 1,n)
def sscore(r):
 n=r[0].lower(); return (0 if any(k in n for k in ('secondary','backup','second')) else 1,n)
primary=min(rows,key=pscore)
rest=[r for r in rows if r!=primary]
secondary=min(rest,key=sscore) if rest else None
with open(sys.argv[2],'w') as f:
 f.write('primary\t'+'\t'.join(primary)+'\n')
 if secondary:f.write('secondary\t'+'\t'.join(secondary)+'\n')
PY
say 'Roles:'; awk -F'\t' '{print "  "$1" = "$2" ("$4")"}' "$TMP/roles.tsv"

say '[6/8] Creating persistent SSH aliases'
CONFIGSSH="$HOME/.ssh/config"; touch "$CONFIGSSH"; chmod 600 "$CONFIGSSH"
python3 - "$CONFIGSSH" <<'PY'
import sys,re,os
p=sys.argv[1]; s=open(p).read() if os.path.exists(p) else ''
s=re.sub(r'\n?# BEGIN CHATGPT A1 SELFHEAL.*?# END CHATGPT A1 SELFHEAL\n?','\n',s,flags=re.S)
open(p,'w').write(s.rstrip()+('\n' if s.strip() else ''))
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
 done < "$TMP/roles.tsv"
 echo '# END CHATGPT A1 SELFHEAL'
} >> "$CONFIGSSH"

say '[7/8] Downloading remote installer and installing on all reachable roles'
API='https://api.github.com/repos/pryins-bit/dcinside-deep-search/contents/oracle-selfheal-remote-v3.sh?ref=main'
curl -fL --retry 3 --retry-delay 2 -H 'Accept: application/vnd.github.raw+json' "$API" -o "$TMP/remote.sh"
chmod +x "$TMP/remote.sh"
while IFS=$'\t' read -r ROLE NAME IID IP USER KEY; do
  say "--- installing $ROLE / $NAME ---"
  scp -q -i "$KEY" -o StrictHostKeyChecking=accept-new "$TMP/remote.sh" "$USER@$IP:/tmp/dc-selfheal-install.sh"
  ssh -i "$KEY" -o StrictHostKeyChecking=accept-new "$USER@$IP" "sudo bash /tmp/dc-selfheal-install.sh '$ROLE'; rm -f /tmp/dc-selfheal-install.sh"
done < "$TMP/roles.tsv"

say '[8/8] Verification and diagnostic collection'
: > "$TMP/summary.txt"
while IFS=$'\t' read -r ROLE NAME IID IP USER KEY; do
  {
    echo "===== $ROLE / $NAME / $IP ====="
    ssh -i "$KEY" -o BatchMode=yes "$USER@$IP" "echo host=\$(uname -n); echo scraper=\$(systemctl is-active dc-scraper.service 2>/dev/null || true); echo watchdog=\$(systemctl is-active dc-scraper-healthcheck.timer 2>/dev/null || true); systemctl list-timers dc-scraper-healthcheck.timer --no-pager 2>/dev/null || true"
  } | tee -a "$TMP/summary.txt"
  scp -q -i "$KEY" "$USER@$IP:/var/log/dc-scraper-health/${ROLE}_latest.txt" "$HOME/${ROLE}_latest.txt" 2>/dev/null || true
done < "$TMP/roles.tsv"

say '=== DONE ==='
say 'SSH aliases:'
say '  ssh a1-primary'
grep -q '^Host a1-secondary$' "$CONFIGSSH" && say '  ssh a1-secondary' || true
say "Report: $REPORT"
say 'Latest diagnostics copied when available:'
ls -lh "$HOME"/*_latest.txt 2>/dev/null || true
