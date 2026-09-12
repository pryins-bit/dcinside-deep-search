#!/usr/bin/env bash
set -Eeuo pipefail
ROLE="${1:-unknown}"
SERVICE="dc-scraper.service"
LOG_DIR="/var/log/dc-scraper-health"
STATE_DIR="/var/lib/dc-scraper-health"
SCRIPT="/usr/local/sbin/dc-scraper-healthcheck"
mkdir -p "$LOG_DIR" "$STATE_DIR"
echo "$ROLE" > "$STATE_DIR/role"

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
HOST="$(uname -n 2>/dev/null || echo host)"
OUT="$LOG_DIR/${ROLE}_${HOST}_${TS}.txt"
LATEST="$LOG_DIR/${ROLE}_latest.txt"
FAILFILE="$STATE_DIR/fail_count"
REBOOTFILE="$STATE_DIR/last_reboot_epoch"
FAILS="$(cat "$FAILFILE" 2>/dev/null || echo 0)"
LAST_REBOOT="$(cat "$REBOOTFILE" 2>/dev/null || echo 0)"
log(){ echo "[$(date -Is)] $*" | tee -a "$OUT"; }
diag(){
  {
    echo "role=$ROLE"; date -Is; uname -a; uptime; free -h; df -h;
    echo '=== service ==='; systemctl status "$SERVICE" --no-pager -l 2>&1 || true;
    echo '=== properties ==='; systemctl show "$SERVICE" -p ActiveState -p SubState -p Result -p MainPID -p ExecMainStatus -p NRestarts -p CPUUsageNSec 2>&1 || true;
    echo '=== processes ==='; ps -eo pid,ppid,user,%cpu,%mem,etime,stat,cmd --sort=-%cpu | head -60;
    echo '=== journal ==='; journalctl -u "$SERVICE" --since '-90 min' --no-pager -n 1200 2>&1 || true;
    echo '=== oom ==='; dmesg -T 2>&1 | grep -Ei 'oom|out of memory|killed process|segfault' | tail -120 || true;
    echo '=== dcinside ==='; curl -I -L --connect-timeout 8 --max-time 15 -A 'Mozilla/5.0' 'https://gall.dcinside.com/mgallery/board/lists/?id=lawschool' 2>&1 | head -60 || true;
  } >> "$OUT" 2>&1
  cp -f "$OUT" "$LATEST"
}
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
  if [[ "$PID" != 0 && ( "$CPU2" != "$CPU1" || "$J1" -gt 0 ) ]]; then
    echo 0 > "$FAILFILE"
    exit 0
  fi
  if ! curl -fsS -I --connect-timeout 8 --max-time 15 -A 'Mozilla/5.0' 'https://gall.dcinside.com/mgallery/board/lists/?id=lawschool' >/dev/null 2>&1; then
    log 'possible external/DCInside outage; keeping service untouched'
    diag
    exit 0
  fi
  log 'suspected hang -> diagnose, kill scraper cgroup, restart'
  diag
  systemctl kill --kill-who=all "$SERVICE" 2>/dev/null || true
  sleep 3
  systemctl restart "$SERVICE" || true
  sleep 20
  if systemctl is-active --quiet "$SERVICE"; then
    echo 0 > "$FAILFILE"
    log 'restart succeeded'
    exit 0
  fi
  FAILS=$((FAILS+1)); echo "$FAILS" > "$FAILFILE"
fi

if (( FAILS >= 3 )) && (( NOW - LAST_REBOOT >= 21600 )); then
  log "repeated failed recoveries ($FAILS) -> controlled reboot"
  diag
  echo "$NOW" > "$REBOOTFILE"
  echo 0 > "$FAILFILE"
  systemctl reboot
fi
EOF
chmod 0755 "$SCRIPT"

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

mkdir -p "/etc/systemd/system/$SERVICE.d"
cat > "/etc/systemd/system/$SERVICE.d/90-selfheal.conf" <<'EOF'
[Service]
Restart=always
RestartSec=15s
TimeoutStopSec=30s
EOF

systemctl daemon-reload
systemctl enable --now dc-scraper-healthcheck.timer
systemctl restart "$SERVICE" || true
sleep 5
systemctl start dc-scraper-healthcheck.service || true

echo "=== INSTALLED role=$ROLE ==="
echo -n "scraper="; systemctl is-active "$SERVICE" || true
echo -n "watchdog_timer="; systemctl is-active dc-scraper-healthcheck.timer || true
systemctl list-timers dc-scraper-healthcheck.timer --no-pager || true
