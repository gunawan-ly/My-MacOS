#!/usr/bin/env bash
# Remote HP-ready: 1 password untuk SSH (user vncuser) + VNC via Tailscale.
# Adaptasi dari dikeckaan/MacOS-Workflow-VNC (fastmac-gui): user baru vncuser
# adalah jalan pintas tembok SecureToken akun runner (dscl passwd user baru
# jalan sebagai root). ngrok/tmate DICOBA dan DIBUANG: ngrok TCP butuh
# verifikasi kartu (ERR_NGROK_8013), DNS *.tmate.io diblokir di pool ini.
# Env: VNC_PASS (password vncuser + VNC), TAILSCALE_AUTHKEY,
#      SSH_PUBLIC_KEY (opsional, untuk debug pemilik repo), KEEP_ALIVE_MINUTES.
set -uo pipefail

VNC_PASS="${VNC_PASS:-}"
TAILSCALE_AUTHKEY="${TAILSCALE_AUTHKEY:-}"
KEEP_ALIVE_MINUTES="${KEEP_ALIVE_MINUTES:-355}"

KC="/System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart"
TCC_DB_USER="$HOME/Library/Application Support/com.apple.TCC/TCC.db"
TCC_DB_SYSTEM="/Library/Application Support/com.apple.TCC/TCC.db"
VNCUSER="vncuser"

log() { printf '[setup-remote] %s\n' "$*"; }

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

# Grant TCC schema-aware (BEST-EFFORT; di image ini SIP disabled jadi biasanya bisa).
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

create_vnc_user() {
  local pw="$1" uid cand
  # Lewat env agar password berkarakter aneh ($, kutip, spasi) tetap aman.
  export VNCUSER="$VNCUSER" VNCUSER_PW="$pw"
  if dscl . -read "/Users/$VNCUSER" UniqueID >/dev/null 2>&1; then
    log "User $VNCUSER sudah ada; set ulang password."
  else
    uid=""
    for cand in $(seq 1001 1010); do
      if ! dscl . -list /Users UniqueID 2>/dev/null | awk '{print $2}' | grep -qx "$cand"; then
        uid="$cand"; break
      fi
    done
    uid="${uid:-1001}"
    log "Membuat user $VNCUSER (uid $uid, admin)..."
    sudo -n dscl . -create "/Users/$VNCUSER" || return 1
    sudo -n dscl . -create "/Users/$VNCUSER" UserShell /bin/bash
    sudo -n dscl . -create "/Users/$VNCUSER" RealName "VNC User"
    sudo -n dscl . -create "/Users/$VNCUSER" UniqueID "$uid"
    sudo -n dscl . -create "/Users/$VNCUSER" PrimaryGroupID 80
    sudo -n dscl . -create "/Users/$VNCUSER" NFSHomeDirectory "/Users/$VNCUSER"
    sudo -n dscl . -append /Groups/admin GroupMembership "$VNCUSER" 2>/dev/null || true
    sudo -n createhomedir -c -u "$VNCUSER" >/dev/null 2>&1 || true
  fi
  if ! run_bounded 30 'sudo -n dscl . -passwd /Users/"$VNCUSER" "$VNCUSER_PW"' >/dev/null 2>&1; then
    log "GAGAL set password $VNCUSER."
    return 1
  fi
  if dscl . -authonly "$VNCUSER" "$pw" >/dev/null 2>&1; then
    log "User $VNCUSER siap (password terverifikasi via authonly)."
  else
    log "GAGAL verifikasi password $VNCUSER."
    return 1
  fi
}

# Pasang operator key (secret SSH_PUBLIC_KEY, bila ada) ke runner + vncuser
# agar pemilik repo tetap bisa SSH langsung via Tailscale untuk debugging.
install_operator_key() {
  [ -z "${SSH_PUBLIC_KEY:-}" ] && return 0
  local u home
  for u in "$(id -un)" "$VNCUSER"; do
    home="$(dscl . -read "/Users/$u" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
    [ -z "$home" ] && continue
    sudo -n install -d -m 700 "$home/.ssh" 2>/dev/null || continue
    {
      printf '%s\n' "$SSH_PUBLIC_KEY"
      [ -f "$home/.ssh/authorized_keys" ] && cat "$home/.ssh/authorized_keys"
    } 2>/dev/null | awk 'NF && !seen[$0]++' | sudo -n tee "$home/.ssh/authorized_keys" >/dev/null 2>&1 || continue
    sudo -n chmod 600 "$home/.ssh/authorized_keys" 2>/dev/null || true
    sudo -n chown -R "$u" "$home/.ssh" 2>/dev/null || sudo -n chown -R "$u:staff" "$home/.ssh" 2>/dev/null || true
  done
  log "Operator key terpasang (bila secret SSH_PUBLIC_KEY ada)."
}

enable_vnc() {
  log "Mengaktifkan Remote Login (sshd) + Screen Sharing (legacy VNC)..."
  run_bounded 30 'sudo -n systemsetup -setremotelogin on' >/dev/null 2>&1 || true
  run_bounded 15 'sudo -n launchctl enable system/com.openssh.sshd' >/dev/null 2>&1 || true
  run_bounded 15 'sudo -n launchctl kickstart -k system/com.openssh.sshd' >/dev/null 2>&1 || true
  run_bounded 10 'sudo -n dseditgroup -o edit -a vncuser -t user com.apple.access_ssh' >/dev/null 2>&1 || true
  sleep 2
  run_bounded 30 "sudo -n \"$KC\" -configure -allowAccessFor -allUsers -privs -all" >/tmp/kc1.log 2>&1 || true
  run_bounded 30 "sudo -n \"$KC\" -configure -clientopts -setvnclegacy -vnclegacy yes" >/tmp/kc2.log 2>&1 || true
  # Password VNC via file hash (trik fastmac-gui; tak bergantung dialog TCC).
  log "Menulis password VNC ke file hash..."
  cat > /tmp/vnchash.py <<'PY_EOF'
import os
key = bytes.fromhex('1734516E8BA8C5E2FF1C39567390ADCA')
pw = os.environ['VNCUSER_PW'][:8].encode()
out = ''.join('%02X' % (b ^ (pw[i] if i < len(pw) else 0)) for i, b in enumerate(key))
open('/tmp/vnchash.txt', 'w').write(out + '\n')
PY_EOF
  if ! run_bounded 20 'python3 /tmp/vnchash.py' >/dev/null 2>&1 || [ ! -s /tmp/vnchash.txt ]; then
    log "GAGAL membuat hash password VNC."
    return 1
  fi
  sudo -n install -m 600 -o root -g wheel /tmp/vnchash.txt /Library/Preferences/com.apple.VNCSettings.txt 2>/dev/null \
    || { sudo -n cp /tmp/vnchash.txt /Library/Preferences/com.apple.VNCSettings.txt 2>/dev/null && sudo -n chmod 600 /Library/Preferences/com.apple.VNCSettings.txt 2>/dev/null; } || return 1
  rm -f /tmp/vnchash.txt /tmp/vnchash.py
  # TCC untuk Screen Sharing (best-effort).
  local SS_APP="/System/Library/CoreServices/Screen Sharing.app/Contents/MacOS/Screen Sharing"
  for db in "$TCC_DB_USER" "$TCC_DB_SYSTEM"; do
    for client in com.apple.ScreenSharing com.apple.screensharing com.apple.RemoteDesktop; do
      for svc in kTCCServiceScreenCapture kTCCServiceAccessibility; do
        tcc_grant "$db" "$svc" "$client" 0
      done
    done
    for svc in kTCCServiceScreenCapture kTCCServiceAccessibility; do
      tcc_grant "$db" "$svc" "$SS_APP" 1
    done
  done
  run_bounded 30 "sudo -n \"$KC\" -restart -agent -console" >/tmp/kc3.log 2>&1 || true
  run_bounded 30 "sudo -n \"$KC\" -activate" >/tmp/kc4.log 2>&1 || true
  log "Screen Sharing aktif."
}

join_tailscale() {
  if [ -z "${TAILSCALE_AUTHKEY:-}" ]; then
    log "GAGAL: secret TAILSCALE_AUTHKEY kosong."
    return 1
  fi
  log "Join tailnet via Tailscale..."
  export HOMEBREW_NO_AUTO_UPDATE=1
  if ! command -v tailscale >/dev/null 2>&1; then
    run_bounded 300 'brew install tailscale' >/tmp/ts-install.log 2>&1 || return 1
  fi
  if ! sudo -n pgrep -x tailscaled >/dev/null 2>&1; then
    sudo -n bash -c 'nohup tailscaled >/tmp/tailscaled.log 2>&1 &' 2>/dev/null || true
    sleep 3
  fi
  local hn="remote-${GITHUB_RUN_ID:-runner}"
  run_bounded 120 "sudo -n tailscale up --authkey='$TAILSCALE_AUTHKEY' --hostname='$hn'" >/dev/null 2>&1 || return 1
  TSIP="$(sudo -n tailscale ip -4 2>/dev/null | head -n1 | tr -d '[:space:]')"
  if [ -z "$TSIP" ]; then
    log "GAGAL mendapatkan IP tailscale."
    return 1
  fi
  log "Tailscale IP: $TSIP"
  if [ -n "${GITHUB_ENV:-}" ]; then
    echo "TSIP=$TSIP" >> "$GITHUB_ENV"
  fi
}

# Self-test framebuffer: vonis jujur DISPLAY-OK / NO-DISPLAY.
check_framebuffer() {
  DISPLAY_OK=no
  local shot=/tmp/remote-selftest.png
  rm -f "$shot"
  if screencapture -x "$shot" 2>/dev/null && [ -f "$shot" ]; then
    local size
    size="$(stat -f%z "$shot" 2>/dev/null || echo 0)"
    if [ "${size:-0}" -gt 1000 ]; then
      DISPLAY_OK=yes
      echo "::notice title=DISPLAY-OK::screencapture ${size} bytes (ada framebuffer, VNC bisa tampil)"
    else
      echo "::warning title=NO-DISPLAY::screencapture ${size} bytes (framebuffer kosong/hitam)"
    fi
  else
    echo "::warning title=NO-DISPLAY::screencapture gagal — VM ini tidak punya display; VNC akan HITAM. SSH tetap bisa."
  fi
  log "Framebuffer display: $DISPLAY_OK"
}

main() {
  if [ -z "$VNC_PASS" ]; then
    log "VNC_PASS kosong; hentikan."
    exit 1
  fi
  if [ "${#VNC_PASS}" -lt 4 ]; then
    log "VNC_PASS minimal 4 karakter; hentikan."
    exit 1
  fi
  if [ -z "$TAILSCALE_AUTHKEY" ]; then
    log "TAILSCALE_AUTHKEY kosong; hentikan."
    exit 1
  fi
  log "macOS: $(sw_vers -productVersion 2>/dev/null || echo unknown) | user setup: $(id -un)"

  create_vnc_user "$VNC_PASS" || exit 1
  install_operator_key || true
  enable_vnc "$VNC_PASS" || exit 1
  join_tailscale || exit 1

  run_bounded 15 'sudo -n pmset -a displaysleep 0 sleep 0 disksleep 0' >/dev/null 2>&1 || true
  local SECONDS=$((KEEP_ALIVE_MINUTES * 60))
  nohup caffeinate -dimsu -t "$SECONDS" >/dev/null 2>&1 &
  sudo -u "$VNCUSER" open -a Finder 2>/dev/null || open -a Finder 2>/dev/null || true
  sleep 3

  check_framebuffer

  echo ""
  echo "===================================================================="
  echo " REMOTE READY (1 password untuk SSH + VNC, via Tailscale)"
  echo ""
  echo "   IP       : ${TSIP:-<ip-tailscale>}"
  echo "   SSH Termux : pkg install openssh -y   (aplikasi Tailscale HP harus ON)"
  echo "                ssh vncuser@${TSIP:-<ip-tailscale>}   -> ketik password -> ENTER"
  echo "   VNC (bVNC): ${TSIP:-<ip-tailscale>}:5900, user vncuser (atau runner)"
  echo "   Pass     : (nilai input password / secret VNC_PASSWORD)"
  echo "   Display  : ${DISPLAY_OK:-unknown} (lihat blok DISPLAY-OK / NO-DISPLAY)"
  echo ""
  echo "   Node ini mati otomatis setelah keep-alive; IP baru tiap run."
  echo "===================================================================="
}

main "$@"
