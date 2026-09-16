#!/usr/bin/env bash
set -uo pipefail

VNC_PASSWORD="${VNC_PASSWORD:-}"
MAC_USER_PASSWORD="${MAC_USER_PASSWORD:-}"
KEEP_ALIVE_MINUTES="${KEEP_ALIVE_MINUTES:-355}"

TSIP="${TSIP:-UNKNOWN}"
TS_HOSTNAME="${TS_HOSTNAME:-UNKNOWN}"
USER_NAME="$(id -un)"
VNC_PORT=5900

echo "=========================================="
echo " VNC READY  (Tailscale + Screen Sharing)"
echo "=========================================="
echo "Runner     : $RUNNER_NAME (macos-latest)"
echo "Tailnet    : $TS_HOSTNAME @ $TSIP"
echo "VNC Address: vnc://$TSIP$([ "$VNC_PORT" != "5900" ] && printf ':%s' "$VNC_PORT")"
echo "VNC user   : $USER_NAME"
echo "Koneksi GUI:"
echo "  - Apple Screen Sharing / Finder: Cmd+K -> vnc://$TSIP"
echo "  - Klien VNC lain (Remmina/RealVNC): host $TSIP :$VNC_PORT"
echo "  - Password VNC (legacy)  : $VNC_PASSWORD"
echo "  - Password akun macOS    : $MAC_USER_PASSWORD (login sebagai $USER_NAME)"
echo "Keep alive : ~${KEEP_ALIVE_MINUTES} menit"
echo "=========================================="

echo "::notice title=VNC-READY::vnc://$TSIP user=$USER_NAME vnc-pass=$VNC_PASSWORD account-pass=$MAC_USER_PASSWORD keep=${KEEP_ALIVE_MINUTES}m"

{
  echo "## macOS Remote Access - VNC Ready"
  echo
  echo "| Field | Value |"
  echo "|---|---|"
  echo "| Runner | \`$RUNNER_NAME\` |"
  echo "| Tailnet node | \`$TS_HOSTNAME\` |"
  echo "| Tailscale IP | \`$TSIP\` |"
  echo "| VNC Address | \`vnc://$TSIP\` |"
  echo "| VNC user | \`$USER_NAME\` |"
  echo "| VNC legacy password | \`$VNC_PASSWORD\` |"
  echo "| macOS account password | \`$MAC_USER_PASSWORD\` |"
  echo "| Keep alive | \`${KEEP_ALIVE_MINUTES}\` menit |"
} >> "$GITHUB_STEP_SUMMARY"