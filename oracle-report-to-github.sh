#!/usr/bin/env bash
set -Eeuo pipefail

TS="$(date +%Y%m%d_%H%M%S)"
OUT="$HOME/oracle_diag_${TS}.txt"
WORK="$HOME/.oracle_diag_repo"
TARGET_REPO="pryins-bit/dcinside-lawschool-search"
TARGET_BRANCH="oracle-diagnostics"
TARGET_DIR="ops/oracle-diagnostics/$TS"

redact() {
  sed -E \
    -e 's/(token|password|secret|private_key|service_role|api[_-]?key)[[:space:]]*=[[:space:]]*[^[:space:]]+/\1=***REDACTED***/Ig' \
    -e 's/(Authorization:[[:space:]]*Bearer[[:space:]]+)[A-Za-z0-9._-]+/\1***REDACTED***/Ig' \
    -e 's/(-----BEGIN [A-Z ]*PRIVATE KEY-----).*/\1 ***REDACTED***/Ig'
}

{
  echo "============================================================"
  echo "ORACLE / DC SCRAPER DIAGNOSTIC REPORT"
  echo "============================================================"
  echo "generated=$(date -Is)"
  echo "shell_node=$(uname -n 2>/dev/null || echo unknown)"
  echo "user=$(id -un 2>/dev/null || echo unknown)"
  echo

  echo "===== CLOUD SHELL ====="
  uname -a 2>&1 || true
  uptime 2>&1 || true
  free -h 2>&1 || true
  df -h 2>&1 || true
  echo

  echo "===== OCI ENV ====="
  env | grep '^OCI_' | sed -E 's/(KEY|TOKEN|SECRET|PASSWORD)=.*/\1=***REDACTED***/I' || true
  echo

  echo "===== OCI CONFIG METADATA ====="
  CFG="${OCI_CLI_CONFIG_FILE:-/etc/oci/config}"
  [[ -f "$CFG" ]] || CFG="$HOME/.oci/config"
  echo "config_path=$CFG"
  if [[ -f "$CFG" ]]; then
    sed -E \
      -e 's/^(key_file|fingerprint|tenancy|user)[[:space:]]*=.*/\1=***PRESENT***/' \
      -e 's/^(pass_phrase)[[:space:]]*=.*/\1=***REDACTED***/' \
      "$CFG" 2>&1 || true
  else
    echo "OCI config not found"
  fi
  echo

  echo "===== OCI CLI VERSION ====="
  oci --version 2>&1 || true
  echo

  echo "===== REGION SUBSCRIPTIONS ====="
  oci iam region-subscription list --all --output table 2>&1 || true
  echo

  echo "===== COMPARTMENTS ====="
  oci iam compartment list --all --compartment-id-in-subtree true --access-level ACCESSIBLE --output table 2>&1 || true
  echo

  echo "===== COMPUTE INSTANCES: CURRENT REGION ====="
  oci compute instance list --all --output table 2>&1 || true
  echo

  echo "===== OCI ONECLICK FILES ====="
  ls -lah "$HOME"/oracle-oneclick*.sh 2>&1 || true
  echo

  echo "===== PRIOR ONECLICK REPORTS ====="
  ls -lah "$HOME"/oracle_a1_selfheal*.txt 2>&1 || true
  for f in "$HOME"/oracle_a1_selfheal*.txt; do
    [[ -f "$f" ]] || continue
    echo "----- $f -----"
    tail -400 "$f" 2>&1 || true
  done
  echo

  echo "===== PRIOR DC SCRAPER DIAG FILES IN CLOUD SHELL ====="
  ls -lah "$HOME"/dc_scraper_full_diag_*.txt 2>&1 || true
  for f in "$HOME"/dc_scraper_full_diag_*.txt; do
    [[ -f "$f" ]] || continue
    echo "----- $f -----"
    tail -500 "$f" 2>&1 || true
  done
  echo

  echo "===== SSH INVENTORY (NO PRIVATE KEY CONTENT) ====="
  ls -lah "$HOME/.ssh" 2>&1 || true
  if [[ -f "$HOME/.ssh/config" ]]; then
    sed -E 's#(^[[:space:]]*IdentityFile[[:space:]]+).*#\1***REDACTED_PATH***#I' "$HOME/.ssh/config" 2>&1 || true
  fi
  echo

  echo "===== NETWORK BASIC ====="
  getent hosts github.com 2>&1 || true
  getent hosts raw.githubusercontent.com 2>&1 || true
  curl -I --connect-timeout 8 --max-time 15 https://api.github.com 2>&1 | head -40 || true
  echo

  echo "===== END ====="
  date -Is
} | redact > "$OUT"

chmod 600 "$OUT"
echo "Diagnostic file created: $OUT"

# Try GitHub CLI first. If Cloud Shell is not authenticated, keep the local file and exit cleanly.
if ! command -v gh >/dev/null 2>&1; then
  echo "GitHub CLI (gh) not installed. Local report is ready: $OUT"
  exit 0
fi

if ! gh auth status >/dev/null 2>&1; then
  echo "GitHub CLI is not authenticated. Local report is ready: $OUT"
  echo "Run: gh auth login"
  exit 0
fi

rm -rf "$WORK"
if ! gh repo clone "$TARGET_REPO" "$WORK" -- --quiet; then
  echo "Could not clone private diagnostic repository. Local report is ready: $OUT"
  exit 0
fi

cd "$WORK"
if git ls-remote --exit-code --heads origin "$TARGET_BRANCH" >/dev/null 2>&1; then
  git checkout -q "$TARGET_BRANCH"
else
  git checkout -q -b "$TARGET_BRANCH"
fi

mkdir -p "$TARGET_DIR"
cp "$OUT" "$TARGET_DIR/cloudshell-report.txt"

cat > "$TARGET_DIR/README.md" <<EOF
# Oracle diagnostic snapshot — $TS

Generated automatically from Oracle Cloud Shell.

- Time: $(date -Is)
- Source: Oracle Cloud Shell
- Purpose: DC scraper / OCI discovery / SSH diagnostics
- Sensitive values: best-effort redacted before upload
- Primary file: cloudshell-report.txt

No VM creation, deletion, restart, or scraper data mutation is performed by this reporter.
EOF

git config user.name "oracle-diagnostics-bot"
git config user.email "oracle-diagnostics@local.invalid"
git add "$TARGET_DIR"
if git diff --cached --quiet; then
  echo "Nothing new to commit."
else
  git commit -q -m "diag: Oracle Cloud Shell snapshot $TS"
  git push -q -u origin "$TARGET_BRANCH"
fi

SHA="$(git rev-parse HEAD)"
echo "============================================================"
echo "Uploaded to private GitHub repository."
echo "Repo: $TARGET_REPO"
echo "Branch: $TARGET_BRANCH"
echo "Path: $TARGET_DIR"
echo "Commit: $SHA"
echo "Local file: $OUT"
echo "============================================================"
