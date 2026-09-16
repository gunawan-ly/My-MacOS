#!/usr/bin/env bash
set -uo pipefail

BIN="/Applications/AnyDesk.app/Contents/MacOS/AnyDesk"
export BIN

# Jalankan perintah CLI dengan batas waktu (mencegah hang).
run_bounded() {
  local secs="$1" pid rc
  shift
  bash -c "$*" &
  pid=$!
  rc=0
  for _ in $(seq 1 "$secs"); do
    if ! kill -0 "$pid" 2>/dev/null; then break; fi
    sleep 1
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    rc=124
  else
    wait "$pid"; rc=$?
  fi
  return "$rc"
}

ID="$(run_bounded 5 'command "$BIN" --get-id 2>/dev/null' 2>/dev/null | tr -d '[:space:]')"
STATUS="$(run_bounded 5 'command "$BIN" --get-status 2>/dev/null' 2>/dev/null | head -1)"
VER="$(run_bounded 5 'command "$BIN" --version 2>/dev/null' 2>/dev/null | head -1)"

# Fallback ke ID yang sudah disimpan configure_anydesk.sh via GITHUB_ENV.
ID="${ID:-${ANYDESK_ID:-UNKNOWN}}"
STATUS="${STATUS:-UNKNOWN}"
VER="${VER:-UNKNOWN}"

echo "=========================================="
echo " ANYDESK READY"
echo "=========================================="
echo "Runner     : $RUNNER_NAME (macos-latest)"
echo "AnyDesk    : $VER"
echo "Address ID : $ID"
echo "Status     : $STATUS"

TCC_DB="$HOME/Library/Application Support/com.apple.TCC/TCC.db"
if [ -f "$TCC_DB" ]; then
  TCC_COUNT="$(sqlite3 "$TCC_DB" \
    "SELECT COUNT(*) FROM access WHERE client='com.philandro.anydesk' AND auth_value=2;" \
    2>/dev/null || echo 0)"
  echo "TCC granted: $TCC_COUNT service(s)"
fi
echo
echo "Cara konek dari PC kamu:"
echo "  1. Buka aplikasi AnyDesk di PC / perangkat client"
echo "  2. Ketik Address ID di atas pada kolom 'Remote Desk'"
echo "  3. Pilih 'Accept and continue' (koneksi unattended)"
echo "  4. Masukkan password = nilai secret ANYDESK_PASSWORD"
echo "=========================================="

{
  echo "## macOS AnyDesk - Ready"
  echo
  echo "| Field | Value |"
  echo "|---|---|"
  echo "| Runner | \`$RUNNER_NAME\` |"
  echo "| AnyDesk Version | $VER |"
  echo "| Address ID | \`$ID\` |"
  echo "| Status | $STATUS |"
} >> "$GITHUB_STEP_SUMMARY"