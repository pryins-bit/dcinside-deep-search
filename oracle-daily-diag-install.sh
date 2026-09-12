#!/usr/bin/env bash
set -Eeuo pipefail

# Install a daily diagnostic collector for an existing scraper VM.
# Safe: does not create/delete/reboot OCI instances and does not modify scraper code.
# Optional GitHub upload works only if the VM already has authenticated git access.

ROLE="${1:-unknown}"
BASE=/var/log/dc-scraper-daily
BIN=/usr/local/sbin/dc-scraper-daily-report
CONF=/etc/dc-scraper-daily.conf
SERVICE=dc-scraper.service

sudo install -d -m 0755 "$BASE"

sudo tee "$CONF" >/dev/null <<EOF
ROLE=$ROLE
GITHUB_REPO=pryins-bit/dcinside-lawschool-search
GITHUB_BRANCH=oracle-diagnostics
EOF

sudo tee "$BIN" >/dev/null <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
source /etc/dc-scraper-daily.conf
TS="$(date +%Y%m%d_%H%M%S)"
HOST="$(uname -n 2>/dev/null || echo unknown)"
OUT="/var/log/dc-scraper-daily/${ROLE}_${HOST}_${TS}.txt"
SAN="${OUT%.txt}.sanitized.txt"

{
  echo "============================================================"
  echo "DC SCRAPER DAILY DIAGNOSTIC"
  echo "============================================================"
  echo "generated=$(date -Is)"
  echo "role=$ROLE"
  echo "host=$HOST"
  echo
  echo "===== SYSTEM ====="
  uptime || true
  free -h || true
  df -hT || true
  echo
  echo "===== SERVICE ====="
  systemctl status dc-scraper.service --no-pager -l 2>&1 || true
  systemctl show dc-scraper.service -p ActiveState -p SubState -p Result -p MainPID -p NRestarts -p CPUUsageNSec 2>&1 || true
  echo
  echo "===== PROCESSES ====="
  ps -eo pid,ppid,user,%cpu,%mem,etime,stat,cmd --sort=-%cpu | head -60 || true
  echo
  echo "===== JOURNAL 24H ====="
  journalctl -u dc-scraper.service --since '-24 hours' --no-pager -n 2500 2>&1 || true
  echo
  echo "===== ERRORS ====="
  journalctl -u dc-scraper.service --since '-24 hours' --no-pager 2>&1 | grep -Ei 'error|exception|traceback|failed|timeout|killed|oom|selenium|chrome|chromium|403|429|502|503|connection|refused|reset|supabase' | tail -500 || true
  echo
  echo "===== KERNEL / OOM ====="
  dmesg -T 2>&1 | grep -Ei 'oom|out of memory|killed process|segfault|python|chrome|chromium' | tail -200 || true
  echo
  echo "===== NETWORK ====="
  curl -I -L --connect-timeout 8 --max-time 15 -A 'Mozilla/5.0' 'https://gall.dcinside.com/mgallery/board/lists/?id=lawschool' 2>&1 | head -60 || true
  echo
  echo "===== SELF-HEAL ====="
  systemctl status dc-scraper-healthcheck.timer --no-pager -l 2>&1 || true
  ls -lh /var/log/dc-scraper-health 2>/dev/null | tail -40 || true
} > "$OUT" 2>&1

sed -E \
  -e 's/(token|password|passwd|secret|service[_ -]?role|private[_ -]?key)([=: ]+)[^ ]+/\1\2***REDACTED***/Ig' \
  -e 's/(Authorization: Bearer )[A-Za-z0-9._-]+/\1***REDACTED***/Ig' \
  "$OUT" > "$SAN" || cp "$OUT" "$SAN"

# Local retention.
find /var/log/dc-scraper-daily -type f -mtime +14 -delete 2>/dev/null || true

# Optional authenticated GitHub push. Never embeds credentials.
# To activate, prepare /opt/dc-diagnostics-repo as an authenticated clone of
# pryins-bit/dcinside-lawschool-search branch oracle-diagnostics.
REPO=/opt/dc-diagnostics-repo
if [[ -d "$REPO/.git" ]] && git -C "$REPO" remote get-url origin >/dev/null 2>&1; then
  if git -C "$REPO" fetch origin oracle-diagnostics >/dev/null 2>&1 && git -C "$REPO" checkout oracle-diagnostics >/dev/null 2>&1; then
    git -C "$REPO" reset --hard origin/oracle-diagnostics >/dev/null 2>&1 || true
    DEST="$REPO/ops/oracle-diagnostics/daily/$ROLE"
    mkdir -p "$DEST"
    cp "$SAN" "$DEST/${TS}.txt"
    git -C "$REPO" add "ops/oracle-diagnostics/daily/$ROLE/${TS}.txt"
    git -C "$REPO" -c user.name=oracle-daily-diag -c user.email=oracle-diag@users.noreply.github.com commit -m "diag: $ROLE daily $TS" >/dev/null 2>&1 || true
    git -C "$REPO" push origin oracle-diagnostics >/dev/null 2>&1 || true
  fi
fi
EOF
sudo chmod 0755 "$BIN"

sudo tee /etc/systemd/system/dc-scraper-daily-report.service >/dev/null <<EOF
[Unit]
Description=Daily DC scraper diagnostic report
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$BIN
EOF

sudo tee /etc/systemd/system/dc-scraper-daily-report.timer >/dev/null <<'EOF'
[Unit]
Description=Run DC scraper diagnostic report daily

[Timer]
OnCalendar=*-*-* 03:20:00
RandomizedDelaySec=20m
Persistent=true

[Install]
WantedBy=timers.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now dc-scraper-daily-report.timer
sudo systemctl start dc-scraper-daily-report.service || true

echo "Installed daily diagnostic timer for role=$ROLE"
sudo systemctl list-timers dc-scraper-daily-report.timer --no-pager || true
sudo ls -lh "$BASE" | tail -20 || true
