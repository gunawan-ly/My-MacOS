#!/usr/bin/env bash
set -uo pipefail

VNC_PASSWORD="${VNC_PASSWORD:-}"
MAC_USER_PASSWORD="${MAC_USER_PASSWORD:-}"
KEEP_ALIVE_MINUTES="${KEEP_ALIVE_MINUTES:-355}"

KICKSTART="/System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart"

log() { printf '[configure-vnc] %s\n' "$*"; }

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

port_listening() {
  (exec 3<>/dev/tcp/127.0.0.1/"$1") 2>/dev/null && { exec 3>&-; exec 3<&-; return 0; }
  return 1
}

# Grant TCC ke satu service+client pada satu database.
# Membaca skema tabel dulu supaya kolomcocok.
tcc_grant() {
  local db="$1" svc="$2" client="$3" ctype="$4"
  # Cek apakah tabel ada
  run_bounded 10 "sudo -n sqlite3 \"$db\" \"SELECT 1 FROM access LIMIT 1;\"" >/dev/null 2>&1 || return 0
  # Baca jumlah kolom
  local ncols
  ncols="$(run_bounded 10 "sudo -n sqlite3 \"$db\" \"PRAGMA table_info(access);\"" 2>/dev/null | wc -l | tr -d ' ')"
  ncols="${ncols:-0}"
  local sql
  if [ "$ncols" -le 10 ]; then
    # Schema lama (≤10 kolom): tanpa kolom tambahan
    sql="INSERT OR REPLACE INTO access (service,client,client_type,auth_value,auth_reason,auth_version) VALUES('$svc','$client',$ctype,2,0,'1');"
  else
    # Schema baru (>10 kolom, macOS 13+): isi kolom opsional dengan NULL/'UNUSED'/0
    sql="INSERT OR REPLACE INTO access (service,client,client_type,auth_value,auth_reason,auth_version,indirect_object_identifier_type,flags,placeholder) VALUES('$svc','$client',$ctype,2,0,'1',0,0,'UNUSED');"
  fi
  run_bounded 10 "sudo -n sqlite3 \"$db\" \"$sql\"" >/dev/null 2>&1 || true
}

# Grant beberapa service TCC ke satu client.
tcc_grant_multi() {
  local db="$1" client="$2" ctype="$3"
  local services=(
    kTCCServiceAccessibility
    kTCCServiceScreenCapture
    kTCCServicePostEvent
    kTCCServiceListenEvent
    kTCCServiceAppleEvents
  )
  for svc in "${services[@]}"; do
    tcc_grant "$db" "$svc" "$client" "$ctype"
  done
}

main() {
  if [ -z "$VNC_PASSWORD" ] || [ -z "$MAC_USER_PASSWORD" ]; then
    log "Secret VNC_PASSWORD / MAC_USER_PASSWORD kosong; hentikan."
    exit 1
  fi
  if [ "${#VNC_PASSWORD}" -gt 8 ]; then
    log "VNC_PASSWORD maksimal 8 karakter untuk legacy VNC; hentikan."
    exit 1
  fi
  if [[ "$VNC_PASSWORD" =~ [[:space:]] ]]; then
    log "VNC_PASSWORD tidak boleh mengandung spasi; hentikan."
    exit 1
  fi

  local USER_NAME
  USER_NAME="$(id -un)"

  # Info dasar
  log "macOS: $(sw_vers -productVersion 2>/dev/null || echo unknown)"
  log "User : $USER_NAME"

  # 1) Aktifkan Screen Sharing + ARD, set password VNC legacy.
  log "Mengaktifkan Screen Sharing (ARD kickstart)..."
  if run_bounded 60 "sudo -n \"$KICKSTART\" -activate -configure -access -on -users \"$USER_NAME\" -restart -agent -privs -all -clientopts -setvnclegacy -vnclegacy yes -setvncpw -vncpw \"$VNC_PASSWORD\"" >/tmp/kickstart.log 2>&1; then
    log "ARD kickstart OK."
  else
    log "ARD kickstart gagal/tidak selesai."
    tail -20 /tmp/kickstart.log 2>/dev/null | sed 's/^/[configure-kickstart] /' || true
    exit 1
  fi

  # 2) Grup akses screensharing.
  if ! run_bounded 10 "sudo -n dscl . -read /Groups/com.apple.access_screensharing" >/dev/null 2>&1; then
    run_bounded 10 "sudo -n dscl . -create /Groups/com.apple.access_screensharing" >/dev/null 2>&1 || true
  fi
  run_bounded 10 "sudo -n dseditgroup -o edit -a \"$USER_NAME\" -t user com.apple.access_screensharing" >/dev/null 2>&1 || true
  log "Grup screensharing OK."

  # 3) Set password akun pengguna.
  log "Mengatur password akun $USER_NAME..."
  if ! run_bounded 30 "sudo -n sysadminctl -resetPasswordFor \"$USER_NAME\" -newPassword \"$MAC_USER_PASSWORD\"" >/dev/null 2>&1; then
    log "sysadminctl gagal; fallback dscl passwd."
    run_bounded 30 "sudo -n dscl . -passwd /Users/\"$USER_NAME\" \"$MAC_USER_PASSWORD\"" >/dev/null 2>&1 || true
  fi

  # 4) TCC: grant ke SEMUA proses yang relevan.
  #    client_type 0 = bundle ID, 1 = path.
  local TCC_DB_USER="$HOME/Library/Application Support/com.apple.TCC/TCC.db"
  local TCC_DB_SYSTEM="/Library/Application Support/com.apple.TCC/TCC.db"

  log "Grant TCC permissions (user + system DB)..."
  for db in "$TCC_DB_USER" "$TCC_DB_SYSTEM"; do
    # Proses path-based (client_type=1)
    tcc_grant_multi "$db" "/usr/sbin/screensharingd" 1
    tcc_grant_multi "$db" "/System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/MacOS/ARDAgent" 1
    tcc_grant_multi "$db" "/bin/bash" 1
    tcc_grant_multi "$db" "/bin/zsh" 1

    # Proses bundle-based (client_type=0)
    tcc_grant_multi "$db" "com.apple.screensharing.agent" 0
    tcc_grant_multi "$db" "com.apple.ScreenSharing" 0
  done

  # Restart TCC daemon agar perubahan terbaca.
  sudo -n launchctl stop com.apple.TCC 2>/dev/null || true
  sleep 2

  # Verifikasi TCC grants
  local tcc_count
  tcc_count="$(run_bounded 10 "sudo -n sqlite3 \"$TCC_DB_USER\" \"SELECT COUNT(*) FROM access WHERE auth_value=2 AND (client LIKE '%screensharing%' OR client LIKE '%ARDAgent%' OR client LIKE '%bash%' OR client LIKE '%zsh%');\"" 2>/dev/null | tr -d '[:space:]')"
  log "TCC auth_value=2 entries (user DB): ${tcc_count:-0}"

  # 5) Restart screensharingd SETELAH TCC grants (agar daemon pick up permissions baru).
  log "Me-restart screensharingd..."
  sudo -n launchctl kickstart -k system/com.apple.screensharing 2>/dev/null || true
  sleep 3

  # 6) Firewall (best-effort).
  local FW
  FW="$(run_bounded 15 'sudo -n /usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate' 2>/dev/null | tr -d ' \n' || true)"
  if [[ "$FW" == *"State=Enabled"* ]]; then
    log "Application Firewall aktif; menambahkan izin."
    run_bounded 15 "sudo -n /usr/libexec/ApplicationFirewall/socketfilterfw --add /usr/sbin/screensharingd" >/dev/null 2>&1 || true
    run_bounded 15 "sudo -n /usr/libexec/ApplicationFirewall/socketfilterfw --add \"$KICKSTART\"" >/dev/null 2>&1 || true
  fi

  # 7) Jaga display tetap menyala.
  run_bounded 15 'sudo -n pmset -a displaysleep 0 sleep 0 disksleep 0' >/dev/null 2>&1 || true
  local SECONDS=$((KEEP_ALIVE_MINUTES * 60))
  nohup caffeinate -dimsu -t "$SECONDS" >/dev/null 2>&1 &
  caffeinate -u -t 2 >/dev/null 2>&1 || true
  log "Display dijaga aktif selama ${KEEP_ALIVE_MINUTES} menit."

  # 8) Wake display secara agresif.
  #    Virtual display di VM sering kali perlu "distur" agar mulai render.
  defaults write com.apple.screensaver idleTime 0 2>/dev/null || true
  # Buka beberapa app GUI untuk force render ke framebuffer.
  open -a Finder 2>/dev/null || true
  sleep 1
  open -a "Terminal" 2>/dev/null || true
  open -a "Activity Monitor" 2>/dev/null || true
  # Set wallpaper (force WindowServer render desktop).
  local WALLPAPER="/System/Library/Desktop Pictures/Default Desktop Picture.png"
  if [ -f "$WALLPAPER" ]; then
    osascript -e "tell application \"System Events\" to tell desktop 1 to set picture to \"$WALLPAPER\"" 2>/dev/null || true
  fi
  # Nudge display awake.
  caffeinate -u -t 5 2>/dev/null || true
  sleep 3
  log "Display di-wake: Terminal + Finder + Activity Monitor + wallpaper."

  # 9) Verifikasi port VNC.
  if port_listening 5900; then
    log "Port 5900 (VNC) LISTENING."
    echo "::notice title=VNC-PORT::port 5900 terbuka"
  else
    log "Peringatan: port 5900 belum terdeteksi LISTENING."
  fi

  # 10) Screencapture test (verifikasi display tidak hitam).
  local sc_size=0
  screencapture -x /tmp/vnc-selftest.png 2>/dev/null && sc_size="$(stat -f%z /tmp/vnc-selftest.png 2>/dev/null || echo 0)"
  log "Screencapture test: ${sc_size} bytes."
  if [ "${sc_size:-0}" -gt 1000 ]; then
    echo "::notice title=DISPLAY-OK::screencapture ${sc_size} bytes (display aktif)"
  else
    echo "::warning title=DISPLAY-BLANK::screencapture ${sc_size} bytes (display mungkin kosong/hitam)"
  fi

  log "Koneksi: vnc://${TSIP:-<tailscale-ip>} user=$USER_NAME"
  log "Setup VNC selesai."
}

main "$@"