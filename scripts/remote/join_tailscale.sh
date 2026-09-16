#!/usr/bin/env bash
set -uo pipefail

export TAILSCALE_AUTHKEY="${TAILSCALE_AUTHKEY:-}"
TS_HOSTNAME="${TS_HOSTNAME:-mac-ci}"

log() { printf '[join-tailscale] %s\n' "$*"; }

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

main() {
  if [ -z "$TAILSCALE_AUTHKEY" ]; then
    log "Secret TAILSCALE_AUTHKEY kosong; hentikan."
    exit 1
  fi

  # 1) Install Tailscale CLI (daemon + client dari Homebrew).
  brew install tailscale >/dev/null 2>&1 || brew install tailscale
  TS_BIN="$(command -v tailscale || echo /opt/homebrew/bin/tailscale)"
  TS_D_BIN="$(command -v tailscaled || echo /opt/homebrew/bin/tailscaled)"
  log "Tailscale CLI: $TS_BIN"

  # 2) Jalankan daemon sebagai root di background. Perlu utun (TUN) supaya
  #    port 5900/22 benar-benar terbuka ke tailnet, bukan sekadar userspace.
  if ! pgrep -x tailscaled >/dev/null 2>&1; then
    sudo -n nohup "$TS_D_BIN" >/tmp/tailscaled.log 2>&1 &
    log "tailscaled dijalankan di background."
  fi

  # 3) Up + auth (bounded, dan pakai --hostname unik per run agar tidak bentrok di tailnet).
  if ! run_bounded 60 "sudo -n \"$TS_BIN\" up --authkey \"$TAILSCALE_AUTHKEY\" --hostname \"$TS_HOSTNAME\"" >/tmp/tailscale-up.log 2>&1; then
    log "tailscale up gagal/tidak selesai dalam 60s."
    tail -20 /tmp/tailscale-up.log 2>/dev/null | sed 's/^/[join-tailscale-up] /' || true
    tail -20 /tmp/tailscaled.log 2>/dev/null | sed 's/^/[join-tailed] /' || true
    exit 1
  fi

  # 4) Tunggu IP tailnet (V4) siap (maks ~60 detik).
  local TSIP="" i
  for i in $(seq 1 20); do
    TSIP="$(run_bounded 5 "sudo -n \"$TS_BIN\" ip -4" 2>/dev/null | tr -d '[:space:]')"
    if [[ "$TSIP" =~ ^100\. ]]; then
      log "IP tailnet diterima: $TSIP (percobaan ke-$i)."
      break
    fi
    TSIP=""
    sleep 3
  done
  if [ -z "$TSIP" ]; then
    log "IP tailnet belum diperoleh; cek /tmp/tailscaled.log."
    sudo -n tail -30 /tmp/tailscaled.log 2>/dev/null | sed 's/^/[join-tailed] /' || true
    exit 1
  fi

  # 5) Ekspos untuk step berikutnya.
  printf 'TSIP=%s\n' "$TSIP" >> "$GITHUB_ENV"
  printf 'TS_HOSTNAME=%s\n' "$TS_HOSTNAME" >> "$GITHUB_ENV"
  echo "::notice title=TAINET::node=$TS_HOSTNAME ip=$TSIP (user keluar: gunakan IP ini)"

  log "Join tailnet selesai. $TS_HOSTNAME -> $TSIP"
}

main "$@"