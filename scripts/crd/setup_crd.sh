#!/usr/bin/env bash
set -uo pipefail

CRD_CODE="${CRD_CODE:-}"
CRD_NAME="${CRD_NAME:-mac-${GITHUB_RUN_ID:-runner}}"
CRD_PIN="${CRD_PIN:-}"
KEEP_ALIVE_MINUTES="${KEEP_ALIVE_MINUTES:-355}"

APP="/Applications/Chrome Remote Desktop Host.app/Contents/MacOS/remoting_start_host"
PLIST="/Library/LaunchAgents/org.chromium.chromoting.plist"
CONFIG_FILE="/Library/PrivilegedHelperTools/org.chromium.chromoting.json"

log() { printf '[setup-crd] %s\n' "$*"; }

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
  if [ -z "$CRD_CODE" ]; then
    log "CRD_CODE kosong; hentikan."
    exit 1
  fi
  case "$CRD_CODE" in
    4/*) ;;
    *) log "CRD_CODE tidak valid (harus mulai '4/'); hentikan."; exit 1 ;;
  esac
  if ! [[ "$CRD_PIN" =~ ^[0-9]{6,}$ ]]; then
    log "CRD_PIN harus angka 6+ digit; hentikan."
    exit 1
  fi

  local USER_NAME
  USER_NAME="$(id -un)"

  log "macOS: $(sw_vers -productVersion 2>/dev/null || echo unknown)"
  log "User : $USER_NAME | Host: $CRD_NAME"

  # 1) Install Chrome Remote Desktop Host.
  if [ -d "/Applications/Chrome Remote Desktop Host.app" ]; then
    log "CRD Host sudah terpasang; skip install."
  else
    log "Menginstall Chrome Remote Desktop Host (brew cask)..."
    if ! run_bounded 300 'command -v brew >/dev/null && brew install --cask chrome-remote-desktop-host' >/tmp/crd-install.log 2>&1; then
      log "brew install gagal; cek log."
      tail -30 /tmp/crd-install.log 2>/dev/null | sed 's/^/[crd-install] /' || true
      exit 1
    fi
    log "CRD Host berhasil diinstall."
  fi
  if [ ! -x "$APP" ]; then
    log "remoting_start_host tidak ditemukan ($APP); hentikan."
    exit 1
  fi

  # 2) Muat LaunchAgent host (setara login ulang).
  local UID_NUM
  UID_NUM="$(id -u)"
  log "Memuat LaunchAgent org.chromium.chromoting (gui/$UID_NUM)?"
  sudo -n launchctl bootout "gui/$UID_NUM/org.chromium.chromoting" 2>/dev/null || true
  if [ -f "$PLIST" ] && run_bounded 15 "sudo -n launchctl bootstrap \"gui/$UID_NUM\" \"$PLIST\"" >/dev/null 2>&1; then
    log "LaunchAgent ter-load."
  else
    log "Peringatan: LaunchAgent gagal di-load (dilanjutkan; host tetap bisa dicoba manual)."
  fi

  # 3) TCC: izinkan akses layar ke host CRD.
  local TCC_DB_USER="$HOME/Library/Application Support/com.apple.TCC/TCC.db"
  local TCC_DB_SYSTEM="/Library/Application Support/com.apple.TCC/TCC.db"
  log "Grant TCC permissions ke CRD Host (user + system DB)..."
  for db in "$TCC_DB_USER" "$TCC_DB_SYSTEM"; do
    tcc_grant_multi "$db" "com.google.ChromeRemoteDesktopHost" 0
    tcc_grant_multi "$db" "com.google.chrome-remote-desktop-host" 0
    tcc_grant_multi "$db" "$APP" 1
    tcc_grant_multi "$db" "/Applications/Chrome Remote Desktop Host.app/Contents/MacOS/chromoting" 1
  done
  sudo -n launchctl stop com.apple.TCC 2>/dev/null || true
  sleep 2
  log "TCC grants selesai."

  # 4) Jaga display menyala + wake.
  wake_display

  # 5) Registrasi headless ke akun Google.
  log "Menjalankan remoting_start_host (auth headless)..."
  local AUTH_LOG=/tmp/crd-auth.log
  : > "$AUTH_LOG"

  # 5a) Percobaan non-interaktif dengan --pin undefined document.
  if run_bounded 60 "\"$APP\" --code=\"$CRD_CODE\" --redirect-url='https://remotedesktop.google.com/_/oauthredirect' --name=\"$CRD_NAME\" --user-name=\"$USER_NAME\" --pin=\"$CRD_PIN\"" >>"$AUTH_LOG" 2>&1; then
    log "Auth OK (mode --pin)."
  else
    # 5b) Fallback: mode interaktif, isi nama + PIN dua kali lewat stdin.
    log "Mode --pin tidak berhasil; fallback interaktif via stdin."
    : > "$AUTH_LOG"
    if run_bounded 90 "printf '%s\n%s\n%s\n' \"$CRD_NAME\" \"$CRD_PIN\" \"$CRD_PIN\" | \"$APP\" --code=\"$CRD_CODE\" --redirect-url='https://remotedesktop.google.com/_/oauthredirect' --name=\"$CRD_NAME\" --user-name=\"$USER_NAME\"" >>"$AUTH_LOG" 2>&1; then
      log "Auth OK (mode interaktif)."
    else
      log "Auth gagal; log:"
      tail -40 "$AUTH_LOG" | sed 's/^/[crd-auth] /' || true
      exit 1
    fi
  fi

  # 6) Verifikasi host aktif.
  sleep 5
  local NR_CONFIG=no NR_HOST=no
  if [ -f "$CONFIG_FILE" ]; then
    NR_CONFIG=yes
  else
    # Beberapa layout menyimpan di /var/root/Library/.
    [ -f "/var/root/Library/Preferences/org.chromium.chromoting.json" ] && NR_CONFIG=yes
  fi
  if pgrep -fl "chromoting" >/dev/null 2>&1; then
    NR_HOST=yes
  fi
  log "Config file: $NR_CONFIG | Proses host: $NR_HOST"
  if [ "$NR_CONFIG" != yes ]; then
    log "Peringatan: config host tidak ditemukan; host mungkin belum me2me-ready."
  fi

  # 7) Self-test screencapture (pembanding bila nanti hitam/hijau).
  local sc_size=0
  screencapture -x /tmp/crd-selftest.png 2>/dev/null && sc_size="$(stat -f%z /tmp/crd-selftest.png 2>/dev/null || echo 0)"
  log "Screencapture test: ${sc_size} bytes."
  if [ "${sc_size:-0}" -gt 1000 ]; then
    echo "::notice title=DISPLAY-OK::screencapture ${sc_size} bytes (display aktif)"
  else
    echo "::warning title=DISPLAY-BLANK::screencapture ${sc_size} bytes (display mungkin kosong)"
  fi

  log "Selesai. Host '$CRD_NAME' seharusnya muncul di app/web Chrome Remote Desktop akun Google pemilik code."
  log "Konek: buka app CRD (HP/desktop) -> pilih '$CRD_NAME' -> masukkan PIN -> Connect."
}

main "$@"