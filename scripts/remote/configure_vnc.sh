#!/usr/bin/env bash
set -uo pipefail

VNC_PASSWORD="${VNC_PASSWORD:-}"
MAC_USER_PASSWORD="${MAC_USER_PASSWORD:-}"
KEEP_ALIVE_MINUTES="${KEEP_ALIVE_MINUTES:-355}"

KICKSTART="/System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart"
SCREENS_SHARING="/System/Library/LaunchDaemons/com.apple.screensharing.plist"

log() { printf '[configure-vnc] %s\n' "$*"; }

# Jalankan perintah dengan batas waktu; mencegah "gantung".
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

  # 1) Aktifkan Screen Sharing + ARD, set password VNC legacy (untuk klien VNC umum).
  log "Mengaktifkan Screen Sharing (ARD kickstart)..."
  if run_bounded 60 "sudo -n \"$KICKSTART\" -activate -configure -access -on -users \"$USER_NAME\" -restart -agent -privs -all -clientopts -setvnclegacy -vnclegacy yes -setvncpw -vncpw \"$VNC_PASSWORD\"" >/tmp/kickstart.log 2>&1; then
    log "ARD kickstart OK."
  else
    log "ARD kickstart gagal/tidak selesai."
    tail -20 /tmp/kickstart.log 2>/dev/null | sed 's/^/[configure-kickstart] /' || true
    exit 1
  fi

  # 2) Pastikan daemon screensharing aktif (fallback bila belum ter-load).
  run_bounded 30 "sudo -n launchctl load -w \"$SCREENS_SHARING\"" >/dev/null 2>&1 || \
    run_bounded 30 'sudo -n launchctl enable system/com.apple.screensharing && sudo -n launchctl bootstrap system /System/Library/LaunchDaemons/com.apple.screensharing.plist' >/dev/null 2>&1 || true
  sleep 3

  # 3) Grup akses screensharing: pastikan ada dan user masuk.
  if ! run_bounded 10 "sudo -n dscl . -read /Groups/com.apple.access_screensharing" >/dev/null 2>&1; then
    run_bounded 10 "sudo -n dscl . -create /Groups/com.apple.access_screensharing" >/dev/null 2>&1 || true
  fi
  run_bounded 10 "sudo -n dseditgroup -o edit -a \"$USER_NAME\" -t user com.apple.access_screensharing" >/dev/null 2>&1 || true
  log "Grup com.apple.access_screensharing dipastikan berisi $USER_NAME."

  # 4) Set password akun pengguna (dipakai saat login melalui Apple Screen Sharing).
  log "Mengatur password akun $USER_NAME..."
  if ! run_bounded 30 "sudo -n sysadminctl -resetPasswordFor \"$USER_NAME\" -newPassword \"$MAC_USER_PASSWORD\"" >/dev/null 2>&1; then
    log "sysadminctl gagal; fallback dscl passwd."
    run_bounded 30 "sudo -n dscl . -passwd /Users/\"$USER_NAME\" \"$MAC_USER_PASSWORD\"" >/dev/null 2>&1 || true
  fi

  # 5) Firewall macOS (best-effort): kalau aktif, izinkan ARD/Screen Sharing.
  local FW
  FW="$(run_bounded 15 'sudo -n /usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate' 2>/dev/null | tr -d ' \n' || true)"
  if [[ "$FW" == *"State=Enabled"* ]]; then
    log "Application Firewall aktif; menambahkan izin ARD/screensharingd."
    run_bounded 15 "sudo -n /usr/libexec/ApplicationFirewall/socketfilterfw --add $KICKSTART" >/dev/null 2>&1 || true
    run_bounded 15 "sudo -n /usr/libexec/ApplicationFirewall/socketfilterfw --add /usr/sbin/screensharingd" >/dev/null 2>&1 || true
  else
    log "Application Firewall tidak aktif; tidak perlu izin tambahan."
  fi

  # 6) Jaga display tetap menyala (biar VNC tidak terlihat hitam) saat keep-alive.
  run_bounded 15 'sudo -n pmset -a displaysleep 0 sleep 0 disksleep 0' >/dev/null 2>&1 || true
  local SECONDS=$((KEEP_ALIVE_MINUTES * 60))
  nohup caffeinate -dimsu -t "$SECONDS" >/dev/null 2>&1 &
  caffeinate -u -t 2 >/dev/null 2>&1 || true
  log "Display dijaga aktif selama ${KEEP_ALIVE_MINUTES} menit."

  # 7) Verifikasi port VNC.
  sleep 2
  if port_listening 5900; then
    log "Port 5900 (VNC) LISTENING."
    echo "::notice title=VNC-PORT::port 5900 terbuka"
  else
    log "Peringatan: port 5900 belum terdeteksi LISTENING; mungkin perlu beberapa detik."
  fi

  log "Koneksi lokasi: vnc://${TSIP:-<tailscale-ip>} (user: $USER_NAME)."
  log "Setup VNC selesai."
}

main "$@"