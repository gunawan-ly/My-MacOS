#!/usr/bin/env bash
set -uo pipefail

BIN="/Applications/AnyDesk.app/Contents/MacOS/AnyDesk"

ID="$("$BIN" --get-id 2>/dev/null | tr -d '[:space:]')"
STATUS="$("$BIN" --get-status 2>/dev/null | head -1)"
VER="$("$BIN" --version 2>/dev/null | head -1)"

ID="${ID:-UNKNOWN}"
STATUS="${STATUS:-UNKNOWN}"
VER="${VER:-UNKNOWN}"

echo "=========================================="
echo " ANYDESK READY"
echo "=========================================="
echo "Runner     : $RUNNER_NAME (macos-latest)"
echo "AnyDesk    : $VER"
echo "Address ID : $ID"
echo "Status     : $STATUS"
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