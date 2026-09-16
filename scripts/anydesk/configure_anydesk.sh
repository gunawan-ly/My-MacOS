#!/usr/bin/env bash
set -uo pipefail

BIN="/Applications/AnyDesk.app/Contents/MacOS/AnyDesk"
export BIN

log() { printf '[configure-anydesk] %s\n' "$*"; }

# Jalankan perintah dengan batas waktu; mencegah "gantung" seperti `open`.
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

get_id() {
  run_bounded 5 'command "$BIN" --get-id 2>/dev/null' 2>/dev/null | tr -d '[:space:]'
}

main() {
  # 1) Launch di GUI session. `open` diprioritaskan (biar attach ke WindowServer),
  #    dan dibatasi waktu. Fallback: eksekusi binary langsung (background).
  if run_bounded 10 open -a AnyDesk >/dev/null 2>&1; then
    log "AnyDesk diluncurkan via launch services."
  else
    log "open tidak selesai 10s / gagal; fallback eksekusi binary langsung."
    nohup "$BIN" >/dev/null 2>&1 &
  fi

  # 2) Tunggu service siap; polling ID numerik (maks ~60 detik).
  local ID="" i
  for i in $(seq 1 12); do
    ID="$(get_id)"
    if [[ "$ID" =~ ^[0-9]{5,}$ ]]; then
      log "AnyDesk ID diterima: $ID (percobaan ke-$i)."
      break
    fi
    ID=""
    if [ "$i" -lt 12 ]; then
      log "Belum siap (percobaan ke-$i/12), menunggu 5 detik..."
      sleep 5
    fi
  done
  [ -n "$ID" ] || log "Peringatan: ID belum diperoleh dalam 60 detik."

  # 3) Password unattended access (nilai tidak pernah di-log).
  if [ -n "${ANYDESK_PASSWORD:-}" ]; then
    log "Mengatur password unattended access..."
    local pw_log
    pw_log="$(mktemp)"
    if run_bounded 20 \
      'if sudo -n true 2>/dev/null; then printf "%s\n" "$ANYDESK_PASSWORD" | sudo -n "$BIN" --set-password; else printf "%s\n" "$ANYDESK_PASSWORD" | "$BIN" --set-password; fi' \
      >"$pw_log" 2>&1; then
      log "Password berhasil di-set."
    else
      log "Peringatan: perintah set-password gagal/tidak selesai."
      if [ -s "$pw_log" ]; then
        log "Output AnyDesk (password di-redact):"
        while IFS= read -r line; do
          log "   $line"
        done < <(perl -pe "s/\Q$ANYDESK_PASSWORD\E/[REDACTED]/g" "$pw_log")
      fi
    fi
    rm -f "$pw_log"
  fi

  # 4) Alias opsional (dari repository/org variable).
  if [ -n "${ANYDESK_ALIAS:-}" ]; then
    if run_bounded 10 '"$BIN" --set-alias "$ANYDESK_ALIAS"' >/dev/null 2>&1; then
      log "Alias di-set: $ANYDESK_ALIAS"
    else
      log "Alias gagal di-set (opsional)."
    fi
  fi

  # 5) Ekspos ID untuk step berikutnya.
  printf 'ANYDESK_ID=%s\n' "${ID:-UNKNOWN}" >> "$GITHUB_ENV"

  log "Setup AnyDesk selesai."
}

main "$@"