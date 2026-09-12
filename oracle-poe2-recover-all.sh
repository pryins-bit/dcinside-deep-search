#!/usr/bin/env bash
set -Eeuo pipefail

TS="$(date +%Y%m%d_%H%M%S)"
LOG="$HOME/dc_scraper_full_diag_${TS}.txt"
UPLOADER="$HOME/oracle-report-to-github.sh"
REPO_API="https://api.github.com/repos/pryins-bit/dcinside-deep-search/contents/oracle-report-to-github.sh?ref=main"
exec > >(tee -a "$LOG") 2>&1

finish(){
  rc=$?
  echo "=== FINAL rc=$rc time=$(date -Is) ==="
  if [[ ! -x "$UPLOADER" ]]; then
    curl -fL --retry 3 -H 'Accept: application/vnd.github.raw+json' "$REPO_API" -o "$UPLOADER" || true
    chmod +x "$UPLOADER" 2>/dev/null || true
  fi
  if [[ -x "$UPLOADER" ]]; then
    bash "$UPLOADER" || true
  else
    echo "Uploader unavailable; local log: $LOG"
  fi
  exit "$rc"
}
trap finish EXIT

echo "=== PO-E2 ONE-SHOT RECOVERY ==="
echo "time=$(date -Is)"

a_need(){ command -v "$1" >/dev/null 2>&1 || { echo "ERROR missing: $1"; return 1; }; }
a_need oci; a_need ssh; a_need ssh-keygen; a_need python3; a_need curl

IID=$(oci search resource structured-search --query-text "query instance resources where displayName = 'po-e2'" --limit 10 --query 'data.items[0].identifier' --raw-output)
[[ -n "$IID" && "$IID" != "null" ]] || { echo "ERROR po-e2 not found"; exit 10; }
COMP=$(oci compute instance get --instance-id "$IID" --query 'data."compartment-id"' --raw-output)
oci compute instance list-vnics --instance-id "$IID" --output json > /tmp/poe2_vnics.json
IP=$(python3 - <<'PY'
import json
j=json.load(open('/tmp/poe2_vnics.json'))
print(next((x.get('public-ip') for x in j.get('data',[]) if x.get('public-ip')),''))
PY
)
echo "IID=$IID"
echo "IP=$IP"

KEY=""
USER=""
if [[ -n "$IP" ]]; then
  for k in "$HOME/.ssh"/*; do
    [[ -f "$k" ]] || continue
    case "$k" in *.pub|*known_hosts*|*config|*authorized_keys*) continue;; esac
    ssh-keygen -y -f "$k" >/dev/null 2>&1 || continue
    for u in ubuntu opc; do
      if ssh -i "$k" -o BatchMode=yes -o ConnectTimeout=7 -o StrictHostKeyChecking=accept-new "$u@$IP" 'echo SSH_OK' 2>/dev/null | grep -qx SSH_OK; then
        KEY="$k"; USER="$u"; break 2
      fi
    done
  done
fi

if [[ -z "$KEY" ]]; then
  echo "No existing SSH key works; trying OCI Run Command recovery"
  REC="$HOME/.ssh/poe2_recovery_rsa"
  if [[ ! -f "$REC" ]]; then
    ssh-keygen -t rsa -b 3072 -N '' -f "$REC"
  fi
  PUB=$(cat "$REC.pub")
  PAYLOAD=$(cat <<EOF
set -e
for u in ubuntu opc; do
  h=/home/\$u
  if id \$u >/dev/null 2>&1 && [ -d \$h ]; then
    mkdir -p \$h/.ssh
    touch \$h/.ssh/authorized_keys
    grep -qxF '$PUB' \$h/.ssh/authorized_keys || echo '$PUB' >> \$h/.ssh/authorized_keys
    chown -R \$u:\$u \$h/.ssh
    chmod 700 \$h/.ssh
    chmod 600 \$h/.ssh/authorized_keys
  fi
done
EOF
)
  python3 - "$PAYLOAD" > /tmp/poe2-content.json <<'PY'
import json,sys
p=sys.argv[1]
print(json.dumps({'source':{'sourceType':'TEXT','text':p},'output':{'outputType':'TEXT'}}))
PY
  printf '{"instanceId":"%s"}\n' "$IID" > /tmp/poe2-target.json
  set +e
  CMDID=$(oci instance-agent command create --compartment-id "$COMP" --content file:///tmp/poe2-content.json --target file:///tmp/poe2-target.json --timeout-in-seconds 120 --display-name "poe2-ssh-recovery-$TS" --query 'data.id' --raw-output 2>&1)
  RC=$?
  set -e
  echo "RunCommand create rc=$RC result=$CMDID"
  if [[ $RC -eq 0 && "$CMDID" == ocid1.* ]]; then
    for i in {1..18}; do
      sleep 5
      oci instance-agent command-execution get --command-id "$CMDID" --instance-id "$IID" --output json > /tmp/poe2-exec.json 2>&1 || true
      cat /tmp/poe2-exec.json
      STATE=$(python3 - <<'PY'
import json
try:
 j=json.load(open('/tmp/poe2-exec.json')); print(j.get('data',{}).get('lifecycle-state',''))
except: print('')
PY
)
      [[ "$STATE" == "SUCCEEDED" ]] && break
      [[ "$STATE" == "FAILED" ]] && break
    done
    KEY="$REC"
    for u in ubuntu opc; do
      if ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=7 -o StrictHostKeyChecking=accept-new "$u@$IP" 'echo SSH_OK' 2>/dev/null | grep -qx SSH_OK; then USER="$u"; break; fi
    done
  fi
fi

if [[ -z "$KEY" || -z "$USER" ]]; then
  echo "ERROR: po-e2 SSH recovery failed. Check Run Command/IAM/Oracle Cloud Agent above."
  exit 20
fi

mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
CFG="$HOME/.ssh/config"; touch "$CFG"; chmod 600 "$CFG"
python3 - "$CFG" <<'PY'
import sys,re
p=sys.argv[1]; s=open(p).read() if __import__('os').path.exists(p) else ''
s=re.sub(r'\n?Host po-e2\n(?:[ \t].*\n)*','\n',s)
open(p,'w').write(s.rstrip()+'\n')
PY
cat >> "$CFG" <<EOF
Host po-e2
  HostName $IP
  User $USER
  IdentityFile $KEY
  IdentitiesOnly yes
  ServerAliveInterval 30
  ServerAliveCountMax 3
  StrictHostKeyChecking accept-new
EOF

echo "=== SSH OK: $USER@$IP via $KEY ==="
ssh po-e2 'hostname; date -Is; sudo systemctl status dc-scraper.service --no-pager -l || true; echo "=== UNIT ==="; sudo systemctl cat dc-scraper.service || true; echo "=== ENV ==="; sudo systemctl show dc-scraper.service -p Environment --no-pager || true; echo "=== JOURNAL 24H ==="; sudo journalctl -u dc-scraper.service --since "24 hours ago" --no-pager | tail -2000 || true; echo "=== LAW SCHOOL FILTER ==="; sudo journalctl -u dc-scraper.service --since "24 hours ago" --no-pager | grep -iE "lawschool|recent cycle|backfill|error|exception|traceback|supabase|403|429|500|selenium|chrome" | tail -1500 || true'

# Conservative repair: restart service; do not overwrite app/config.
ssh po-e2 'sudo systemctl restart dc-scraper.service; sleep 8; sudo systemctl status dc-scraper.service --no-pager -l || true; sudo journalctl -u dc-scraper.service --since "10 minutes ago" --no-pager | tail -400 || true'

echo "=== DONE: ssh po-e2 ==="
