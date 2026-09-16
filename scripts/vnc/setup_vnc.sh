#!/usr/bin/env bash
set -uo pipefail

VNC_PASSWORD="${VNC_PASSWORD:-}"
KEEP_ALIVE_MINUTES="${KEEP_ALIVE_MINUTES:-355}"

KC="/System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart"
TCC_DB_USER="$HOME/Library/Application Support/com.apple.TCC/TCC.db"
TCC_DB_SYSTEM="/Library/Application Support/com.apple.TCC/TCC.db"

log() { printf '[setup-vnc] %s\n' "$*"; }

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

# Grant TCC untuk satu service+client pada satu database (schema-aware).
tcc_grant() {
  local db="$1" svc="$2" client="$3" ctype="$4"
  run_bounded 10 "sudo -n sqlite3 \"$db\" \"SELECT 1 FROM access LIMIT 1;\"" >/dev/null 2>&1 || return 0
  local ncols
  ncols="$(run_bounded 10 "sudo -n sqlite3 \"$db\" \"PRAGMA table_info(access);\"" 2>/dev/null | wc -l | tr -d ' ')"
  ncols="${ncols:-0}"
  local sql
  if [ "$ncols" -le 10 ]; then
    sql="INSERT OR REPLACE INTO access (service,client,client_type,auth_value,auth_reason,auth_version) VALUES('$svc','$client',$ctype,2,0,'1');"
  else
    sql="INSERT OR REPLACE INTO access (service,client,client_type,auth_value,auth_reason,auth_version,indirect_object_identifier_type,flags,placeholder) VALUES('$svc','$client',$ctype,2,0,'1',0,0,'UNUSED');"
  fi
  run_bounded 10 "sudo -n sqlite3 \"$db\" \"$sql\"" >/dev/null 2>&1 || true
}

tcc_grant_multi() {
  local db="$1" client="$2" ctype="$3"
  local services=(
    kTCCServiceScreenCapture
    kTCCServiceAccessibility
    kTCCServicePostEvent
    kTCCServiceListenEvent
    kTCCServiceAppleEvents
  )
  for svc in "${services[@]}"; do
    tcc_grant "$db" "$svc" "$client" "$ctype"
  done
}

wake_display() {
  run_bounded 15 'sudo -n pmset -a displaysleep 0 sleep 0 disksleep 0' >/dev/null 2>&1 || true
  local SECONDS=$((KEEP_ALIVE_MINUTES * 60))
  nohup caffeinate -dimsu -t "$SECONDS" >/dev/null 2>&1 &
  caffeinate -u -t 2 >/dev/null 2>&1 || true

  defaults write com.apple.screensaver idleTime 0 2>/dev/null || true
  open -a Finder 2>/dev/null || true
  sleep 1
  open -a "Terminal" 2>/dev/null || true
  open -a "Activity Monitor" 2>/dev/null || true
  local WALLPAPER="/System/Library/Desktop Pictures/Default Desktop Picture.png"
  if [ -f "$WALLPAPER" ]; then
    osascript -e "tell application \"System Events\" to tell desktop 1 to set picture to \"$WALLPAPER\"" 2>/dev/null || true
  fi
  caffeinate -u -t 5 2>/dev/null || true
  sleep 3
  log "Display dijaga aktif selama ${KEEP_ALIVE_MINUTES} menit."
}

main() {
  if [ -z "$VNC_PASSWORD" ]; then
    log "VNC_PASSWORD kosong; hentikan."
    exit 1
  fi
  if [ "${#VNC_PASSWORD}" -lt 8 ]; then
    log "VNC_PASSWORD minimal 8 karakter; hentikan."
    exit 1
  fi

  log "macOS: $(sw_vers -productVersion 2>/dev/null || echo unknown)"
  log "User : $(id -un)"

  # 1) Aktifkan Screen Sharing (Apple Remote Management) + active VNC legacy + password.
  log "Mengaktifkan Screen Sharing (VNC) via kickstart..."
  run_bounded 30 "sudo -n \"$KC\" -activate -configure -access -on -clientopts -setvnclegacy -vnclegacy yes -clientopts -setvncpw -vncpw \"$VNC_PASSWORD\" -restart -agent -console" >/tmp/vnc-kickstart.log 2>&1
  cat /tmp/vnc-kickstart.log | sed 's/^/[kickstart] /' || true

  # 2) Pastikan daemon screensharingd di-spawn ulang otomatis oleh kernel saat ada
  #    koneksi masuk (socket activation). Ini membuat port 5900 tetap "hidup" meski
  #    daemon idle-exit ~15 detik setelah viewer terakhir terputus.
  run_bounded 15 'sudo -n launchctl enable system/com.apple.screensharing' >/dev/null 2>&1 || true
  sleep 2

  # 3) TCC: izinkan Screen Sharing (daemon + app + RemoteManagement) meng-capture layar.
  log "Grant TCC permissions ke Screen Sharing (user + system DB)..."
  local SS_APP="/System/Library/CoreServices/Screen Sharing.app/Contents/MacOS/Screen Sharing"
  for db in "$TCC_DB_USER" "$TCC_DB_SYSTEM"; do
    for client in com.apple.ScreenSharing com.apple.screensharing com.apple.RemoteDesktop; do
      tcc_grant_multi "$db" "$client" 0
    done
    tcc_grant_multi "$db" "$SS_APP" 1
  done
  sudo -n launchctl stop com.apple.TCC 2>/dev/null || true
  sleep 2
  log "TCC grants selesai."

  # 4) Jaga display menyala + wake.
  wake_display

  # 5) Verifikasi VNC listening di 5900.
  sleep 3
  local PORT_OK=no
  if netstat -an 2>/dev/null | grep -q "\.5900 .*LISTEN"; then
    PORT_OK=yes
  fi
  if [ "$PORT_OK" = yes ]; then
    echo "::notice title=VNC-OK::Port 5900 LISTEN (legacy VNC aktif)"
  else
    echo "::warning title=VNC-CHECK::Port 5900 tidak terdeteksi; cek wake/daemon di loop keep-alive"
  fi
  log "VNC listen 5900: $PORT_OK"

  # 6) Ambil IP tailnet (dipakai client untuk koneksi), dari env atau fallback.
  local TSIP="${TSIP:-}"
  if [ -z "$TSIP" ]; then
    TSIP="$(sudo -n tailscale ip -4 2>/dev/null | head -n1 | tr -d '[:space:]')"
  fi
  if [ -n "${GITHUB_ENV:-}" ]; then
    echo "VNC_HOST=${TSIP:-<ip-tailscale>}" >> "$GITHUB_ENV"
  fi

  echo ""
  echo "===================================================================="
  echo " VNC READY"
  echo ""
  echo "   Host : ${TSIP:-<ip-tailscale>}:5900   (VNC / RFB 003.889)"
  echo "   User : $(id -un)"
  echo "   Pass : (nilai secret VNC_PASSWORD, min 8 karakter)"
  echo ""
  echo "   Client : bVNC (Android) / RealVNC Viewer TIDAK didukung (versi 3.889)"
  echo "   Catat  : HP harus join ke TAILNET yang sama (node pemilik authkey)."
  echo "===================================================================="
}

main "$@"