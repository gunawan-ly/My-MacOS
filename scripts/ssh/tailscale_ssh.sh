#!/usr/bin/env bash
set -uo pipefail

TAILSCALE_AUTHKEY="${TAILSCALE_AUTHKEY:-}"
TS_HOSTNAME="${TS_HOSTNAME:-mac-runner}"
SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY:-}"
MAC_USER_PASSWORD="${MAC_USER_PASSWORD:-}"

log() { printf '[tailscale-ssh] %s\n' "$*"; }

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

start_tailscaled() {
  if ! sudo -n pgrep -x tailscaled >/dev/null 2>&1; then
    log "Memulai tailscaled (root)..."
    # Pakai path default (/var/run/tailscaled.socket & /Library/Tailscale)
    # supaya konsisten dengan default yang dicari oleh CLI 'tailscale'.
    sudo -n bash -c 'nohup tailscaled >/tmp/tailscaled.log 2>&1 &'
    sleep 3
    sudo -n pgrep -x tailscaled >/dev/null 2>&1 || {
      log "tailscaled tidak berjalan; log:"
      tail -20 /tmp/tailscaled.log 2>/dev/null | sed 's/^/  /' || true
      return 1
    }
  else
    log "tailscaled sudah berjalan."
  fi
  return 0
}

enable_ssh() {
  log "Mengaktifkan Remote Login (sshd)..."
  run_bounded 30 'sudo -n systemsetup -setremotelogin on' >/dev/null 2>&1 || true
  if ! sudo -n pgrep -f sshd >/dev/null 2>&1; then
    run_bounded 15 'sudo -n launchctl enable system/com.openssh.sshd' >/dev/null 2>&1 || true
    run_bounded 15 'sudo -n launchctl kickstart -k system/com.openssh.sshd' >/dev/null 2>&1 || true
  fi
  sleep 2

  local USER_NAME
  USER_NAME="$(id -un)"

  # Login dengan password hanya PAKAI BUNTUT bila tidak ada public key (macOS VM
  # sering menolak dscl tanpa SecureToken sehingga password kerap gagal).
  if [ -z "$SSH_PUBLIC_KEY" ] && [ -n "$MAC_USER_PASSWORD" ]; then
    log "Mengatur password akun $USER_NAME (best-effort)..."
    run_bounded 30 "sudo -n sysadminctl -resetPasswordFor \"$USER_NAME\" -newPassword \"$MAC_USER_PASSWORD\"" >/dev/null 2>&1 \
      || run_bounded 30 "sudo -n dscl . -passwd /Users/\"$USER_NAME\" \"$MAC_USER_PASSWORD\"" >/dev/null 2>&1 \
      || log "Peringatan: pengaturan password gagal; login password mungkin tidak jalan."
  fi

  # Pastikan user masuk grup Remote Login.
  run_bounded 10 "sudo -n dseditgroup -o edit -a \"$USER_NAME\" -t user com.apple.access_ssh" >/dev/null 2>&1 || true

  # Login dengan public key (paling andal).
  if [ -n "$SSH_PUBLIC_KEY" ]; then
    log "Memasang SSH public key ke $USER_NAME..."
    sudo -n install -d -m 700 "/Users/$USER_NAME/.ssh"
    {
      printf '%s\n' "$SSH_PUBLIC_KEY"
      [ -f "/Users/$USER_NAME/.ssh/authorized_keys" ] && cat "/Users/$USER_NAME/.ssh/authorized_keys"
    } | awk 'NF && !seen[$0]++' | sudo -n tee "/Users/$USER_NAME/.ssh/authorized_keys" >/dev/null
    sudo -n chmod 600 "/Users/$USER_NAME/.ssh/authorized_keys"
    sudo -n chown -R "$USER_NAME":staff "/Users/$USER_NAME/.ssh"
    log "Public key terpasang."
  fi

  log "Remote Login aktif untuk user $USER_NAME."
}

main() {
  if [ -z "$TAILSCALE_AUTHKEY" ]; then
    log "TAILSCALE_AUTHKEY kosong; hentikan."
    exit 1
  fi

  # 1) Install CLI Tailscale bila belum ada.
  if ! command -v tailscale >/dev/null 2>&1; then
    log "Menginstall tailscale CLI (brew)..."
    if ! run_bounded 300 'export HOMEBREW_NO_AUTO_UPDATE=1 && brew install tailscale' >/tmp/ts-install.log 2>&1; then
      log "brew install tailscale gagal; log:"
      tail -30 /tmp/ts-install.log 2>/dev/null | sed 's/^/  /' || true
      exit 1
    fi
    log "tailscale CLI terinstall."
  fi

  start_tailscaled || exit 1

  # 2) Join tailnet.
  log "tailscale up ($TS_HOSTNAME)..."
  if ! run_bounded 120 "sudo -n tailscale up --authkey='$TAILSCALE_AUTHKEY' --hostname='$TS_HOSTNAME'"; then
    log "tailscale up gagal; status/log:"
    sudo -n tailscale status 2>&1 | sed 's/^/  /' || true
    tail -20 /tmp/tailscaled.log 2>/dev/null | sed 's/^/  /' || true
    exit 1
  fi
  log "tailscale up OK."

  # 3) Ambil IP di tailnet.
  local TSIP
  TSIP="$(sudo -n tailscale ip -4 2>/dev/null | head -n1 | tr -d '[:space:]')"
  TSIP="${TSIP:-}"
  if [ -z "$TSIP" ]; then
    log "Tidak dapat IP tailscale; jalankan sudo tailscale ip saat di run."
    echo "::warning::tailscale ip -4 kosong"
  else
    log "Tailscale IP: $TSIP"
    if [ -n "${GITHUB_ENV:-}" ]; then
      echo "TSIP=$TSIP" >> "$GITHUB_ENV"
    fi
  fi

  # 4) Aktifkan SSH.
  enable_ssh

  # 5) Ringkasan akses.
  echo ""
  echo "===================================================================="
  echo " SSH READY"
  echo ""
  echo "   ssh runner@${TSIP:-<ip-tailscale>}"
  echo ""
  if [ -n "$SSH_PUBLIC_KEY" ]; then
    echo "   Auth : public key (~/.ssh/id_*.pub) milik pemilik secret SSH_PUBLIC_KEY"
  elif [ -n "$MAC_USER_PASSWORD" ]; then
    echo "   Auth : password akun runner (= nilai secret MAC_USER_PASSWORD)"
  fi
  echo "   Catat : perangkat kamu harus join ke TAILNET yang sama (node pemilik authkey)."
  echo "===================================================================="
}

main "$@"