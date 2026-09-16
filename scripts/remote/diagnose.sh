#!/usr/bin/env bash
set -uo pipefail

log() { printf '[diagnose] %s\n' "$*"; }

log "=== macOS Version ==="
sw_vers 2>/dev/null || true
printf 'uname: %s\n' "$(uname -a 2>/dev/null)"

log "=== User Info ==="
printf 'whoami: %s\n' "$(id -un 2>/dev/null)"
printf 'uid/gid: %s\n' "$(id 2>/dev/null)"

log "=== Tailscale ==="
sudo -n tailscale status 2>/dev/null | head -10 || log "tailscale status: gagal"
printf 'TSIP: %s\n' "${TSIP:-N/A}"

log "=== Screen Sharing Service ==="
sudo -n launchctl print system/com.apple.screensharing 2>/dev/null | head -15 || log "screensharing service: tidak ditemukan"
sudo -n launchctl list 2>/dev/null | grep -i screen || true

log "=== Port VNC (5900) ==="
(netstat -an 2>/dev/null | grep -E '\.5900 ' | head -5) || log "netstat: tidak ada"
lsof -nP -iTCP:5900 -sTCP:LISTEN 2>/dev/null | head -5 || log "lsof: tidak ada"

log "=== Display Info ==="
system_profiler SPDisplaysDataType 2>/dev/null | grep -E 'Resolution|Display Type|Online|Main Display|Retina' | head -15 || log "SPDisplaysDataType: gagal"
printf 'console user: %s\n' "$(stat -f %Su /dev/console 2>/dev/null || echo n/a)"
pmset -g 2>/dev/null | grep -E 'sleep |displaysleep |disksleep ' || true

log "=== Screensaver ==="
defaults -currentHost read com.apple.screensaver idleTime 2>/dev/null || log "idleTime: default"

log "=== TCC Database (user) ==="
TCC_DB="$HOME/Library/Application Support/com.apple.TCC/TCC.db"
if [ -f "$TCC_DB" ]; then
  log "TCC DB: $TCC_DB"
  log "Schema (kolom access):"
  sudo -n sqlite3 "$TCC_DB" "PRAGMA table_info(access);" 2>/dev/null | head -20 || true
  log "Semua auth_value=2 (granted):"
  sudo -n sqlite3 "$TCC_DB" "SELECT service, client, client_type, auth_value FROM access WHERE auth_value=2 ORDER BY service;" 2>/dev/null | head -30 || true
  log "screensharingd entries:"
  sudo -n sqlite3 "$TCC_DB" "SELECT service, client, client_type, auth_value FROM access WHERE client LIKE '%screensharing%' OR client LIKE '%ARDAgent%' OR client LIKE '%bash%' OR client LIKE '%zsh%';" 2>/dev/null || true
else
  log "TCC DB user: tidak ditemukan"
fi

log "=== TCC Database (system) ==="
TCC_SYS="/Library/Application Support/com.apple.TCC/TCC.db"
if [ -f "$TCC_SYS" ]; then
  log "TCC DB: $TCC_SYS"
  log "screensharingd entries:"
  sudo -n sqlite3 "$TCC_SYS" "SELECT service, client, client_type, auth_value FROM access WHERE client LIKE '%screensharing%' OR client LIKE '%ARDAgent%';" 2>/dev/null || true
else
  log "TCC DB system: tidak ditemukan"
fi

log "=== Screencapture Test ==="
screencapture -x /tmp/diag-screencapture.png 2>&1 || true
if [ -f /tmp/diag-screencapture.png ]; then
  SC_SIZE="$(stat -f%z /tmp/diag-screencapture.png 2>/dev/null || echo 0)"
  log "screencapture: ${SC_SIZE} bytes."
  if [ "${SC_SIZE:-0}" -lt 1000 ]; then
    log "PERINGATAN: screencapture sangat kecil — display kemungkinan kosong/hitam."
  fi
else
  log "screencapture: file tidak dibuat."
fi

log "=== Active Processes (screensharing/ARD) ==="
ps aux 2>/dev/null | grep -iE 'screensharing|ARD|vnc' | grep -v grep || log "tidak ada proses screensharing/ARD aktif."

log "=== WindowServer ==="
ps aux 2>/dev/null | grep -i WindowServer | grep -v grep | head -3 || log "WindowServer: tidak ditemukan"

log "=== GUI Session ==="
launchctl print gui/$(id -u) 2>/dev/null | grep -E 'type|session|creator|Aqua' | head -5 || log "gui session: tidak ditemukan"

log "=== Diagnosa selesai ==="