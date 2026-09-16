#!/usr/bin/env bash
# Setup remote ala fastmac-gui (dikeckaan/MacOS-Workflow-VNC), dimodernisasi:
# user baru vncuser (jalan pintas tembok SecureToken akun runner), password VNC
# via file hash, tunnel ngrok untuk VNC, SSH via tmate (step workflow terpisah).
# Env: VNC_PASS (dipakai untuk password login vncuser SEKALIGUS password VNC),
#      NGROK_AUTH_TOKEN, KEEP_ALIVE_MINUTES.
set -uo pipefail

VNC_PASS="${VNC_PASS:-}"
NGROK_AUTH_TOKEN="${NGROK_AUTH_TOKEN:-}"
KEEP_ALIVE_MINUTES="${KEEP_ALIVE_MINUTES:-355}"

KC="/System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart"
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

enable_vnc() {
  local pw="$1"
  log "Mengaktifkan Remote Login (sshd) + Screen Sharing (legacy VNC)..."
  run_bounded 30 'sudo -n systemsetup -setremotelogin on' >/dev/null 2>&1 || true
  run_bounded 15 'sudo -n launchctl enable system/com.openssh.sshd' >/dev/null 2>&1 || true
  run_bounded 15 'sudo -n launchctl kickstart -k system/com.openssh.sshd' >/dev/null 2>&1 || true
  run_bounded 10 'sudo -n dseditgroup -o edit -a vncuser -t user com.apple.access_ssh' >/dev/null 2>&1 || true
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
  rm -f /tmp/vnchash.txt
  run_bounded 30 "sudo -n \"$KC\" -restart -agent -console" >/tmp/kc3.log 2>&1 || true
  run_bounded 30 "sudo -n \"$KC\" -activate" >/tmp/kc4.log 2>&1 || true
  log "Screen Sharing aktif."
}

start_ngrok() {
  log "Install ngrok (bila belum ada)..."
  if ! command -v ngrok >/dev/null 2>&1; then
    export HOMEBREW_NO_AUTO_UPDATE=1
    if ! run_bounded 300 'brew install --cask ngrok' >/tmp/ngrok-install.log 2>&1; then
      log "brew install ngrok gagal."
      tail -10 /tmp/ngrok-install.log 2>/dev/null | sed 's/^/[ngrok] /' || true
      return 1
    fi
  fi
  export NGROK_TOKEN="$NGROK_AUTH_TOKEN"
  run_bounded 30 'ngrok config add-authtoken "$NGROK_TOKEN"' >/dev/null 2>&1 \
    || run_bounded 30 'ngrok authtoken "$NGROK_TOKEN"' >/dev/null 2>&1 || true
  pkill -f 'ngrok tcp 5900' 2>/dev/null || true
  nohup ngrok tcp 5900 >/tmp/ngrok.log 2>&1 &
  sleep 3
  local url="" i
  for i in $(seq 1 20); do
    url="$(curl -s --max-time 5 http://127.0.0.1:4040/api/tunnels 2>/dev/null | python3 -c "import json,sys; ts=json.load(sys.stdin).get('tunnels',[]); print(ts[0]['public_url'] if ts else '')" 2>/dev/null)"
    [ -n "$url" ] && break
    sleep 3
  done
  if [ -z "$url" ]; then
    log "ngrok gagal (cek /tmp/ngrok.log) — kemungkinan akun butuh verifikasi kartu (ERR_NGROK_8013)."
    tail -6 /tmp/ngrok.log 2>/dev/null | sed 's/^/[ngrok] /' || true
    return 1
  fi
  NGROK_URL="$url"
  log "ngrok: $NGROK_URL -> 5900"
  if [ -n "${GITHUB_ENV:-}" ]; then
    echo "NGROK_URL=$NGROK_URL" >> "$GITHUB_ENV"
  fi
}

# Fallback bila ngrok menolak (mis. akun gratis tanpa verifikasi kartu):
# VNC lewat Tailscale (butuh secret TAILSCALE_AUTHKEY). HP harus join tailnet
# yang sama (atau pakai tmate untuk SSH yang selalu bisa).
fallback_tailscale() {
  if [ -z "${TAILSCALE_AUTHKEY:-}" ]; then
    log "GAGAL: ngrok gagal dan secret TAILSCALE_AUTHKEY kosong."
    return 1
  fi
  log "Fallback: join tailnet via Tailscale..."
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

# tmate MANUAL (satu sesi; action-tmate detached memicu error server
# "multi sessions is not supported"). Baris SSH dicetak via ::notice agar
# terlihat LIVE di halaman run + di blok READY.
start_tmate() {
  export HOMEBREW_NO_AUTO_UPDATE=1
  if ! command -v tmate >/dev/null 2>&1; then
    log "Install tmate..."
    if ! run_bounded 300 'brew install tmate' >/tmp/tmate-install.log 2>&1; then
      log "brew install tmate gagal."
      return 1
    fi
  fi
  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh" 2>/dev/null || true
  if [ ! -f "$HOME/.ssh/id_ed25519" ] && [ ! -f "$HOME/.ssh/id_rsa" ]; then
    ssh-keygen -t ed25519 -f "$HOME/.ssh/id_ed25519" -N '' -C "tmate-runner" >/dev/null 2>&1 || true
  fi
  local SOCK=/tmp/tmate.sock
  rm -f "$SOCK"
  if ! run_bounded 60 "tmate -S $SOCK new-session -d 'sleep 21000'" >/tmp/tmate-new.log 2>&1; then
    log "tmate new-session gagal:"
    tail -5 /tmp/tmate-new.log 2>/dev/null | sed 's/^/[tmate] /' || true
    return 1
  fi
  if ! run_bounded 90 "tmate -S $SOCK wait tmate-ready" >/tmp/tmate-wait.log 2>&1; then
    log "tmate tidak ready:"
    tail -5 /tmp/tmate-wait.log 2>/dev/null | sed 's/^/[tmate] /' || true
    return 1
  fi
  TMATE_SSH="$(tmate -S "$SOCK" display -p '#{tmate_ssh}' 2>/dev/null)"
  TMATE_WEB="$(tmate -S "$SOCK" display -p '#{tmate_web}' 2>/dev/null)"
  if [ -z "$TMATE_SSH" ]; then
    log "GAGAL membaca alamat tmate."
    return 1
  fi
  echo "::notice title=TMATE-SSH::$TMATE_SSH"
  [ -n "$TMATE_WEB" ] && echo "::notice title=TMATE-WEB::$TMATE_WEB"
  log "tmate siap: $TMATE_SSH"
  if [ -n "${GITHUB_ENV:-}" ]; then
    echo "TMATE_SSH=$TMATE_SSH" >> "$GITHUB_ENV"
    echo "TMATE_WEB=$TMATE_WEB" >> "$GITHUB_ENV"
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
    echo "::warning title=NO-DISPLAY::screencapture gagal — VM ini tidak punya display; VNC akan HITAM. SSH via tmate tetap bisa."
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
  if [ -z "$NGROK_AUTH_TOKEN" ]; then
    log "NGROK_AUTH_TOKEN kosong; hentikan."
    exit 1
  fi
  log "macOS: $(sw_vers -productVersion 2>/dev/null || echo unknown) | user setup: $(id -un)"

  create_vnc_user "$VNC_PASS" || exit 1
  install_operator_key || true
  enable_vnc "$VNC_PASS" || exit 1
  if ! start_ngrok; then
    log "ngrok gagal — fallback ke Tailscale untuk VNC."
    fallback_tailscale || exit 1
  fi

  run_bounded 15 'sudo -n pmset -a displaysleep 0 sleep 0 disksleep 0' >/dev/null 2>&1 || true
  local SECONDS=$((KEEP_ALIVE_MINUTES * 60))
  nohup caffeinate -dimsu -t "$SECONDS" >/dev/null 2>&1 &
  sudo -u "$VNCUSER" open -a Finder 2>/dev/null || open -a Finder 2>/dev/null || true
  sleep 3

  check_framebuffer

  start_tmate || echo "::warning::tmate gagal dimulai; SSH fallback via Tailscale secret bila ada."

  echo ""
  echo "===================================================================="
  if [ -n "${NGROK_URL:-}" ]; then
    echo " VNC READY (via ngrok, TANPA perlu Tailscale di HP)"
    echo ""
    echo "   Endpoint : $NGROK_URL"
  else
    echo " VNC READY (via Tailscale — ngrok butuh verifikasi kartu, fallback aktif)"
    echo ""
    echo "   Endpoint : ${TSIP:-<ip-tailscale>}:5900 (HP harus join tailnet yang sama)"
  fi
  echo "   User     : $VNCUSER  (atau runner, password sama)"
  echo "   Pass     : (nilai input password / secret VNC_PASSWORD)"
  echo "   Display  : ${DISPLAY_OK:-unknown} (lihat blok DISPLAY-OK / NO-DISPLAY)"
  echo ""
  echo "   Client   : bVNC (Android). Host+port dari endpoint di atas."
  echo "   SSH-tmate: ${TMATE_SSH:-<lihat notice TMATE-SSH di log>}"
  echo "     Termux : pkg install openssh -y, tempel baris SSH di atas, ENTER."
  [ -n "${TMATE_WEB:-}" ] && echo "   SSH-web  : $TMATE_WEB (terminal di browser HP)"
  echo "===================================================================="
}

main "$@"
