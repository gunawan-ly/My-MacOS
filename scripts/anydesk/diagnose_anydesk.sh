#!/usr/bin/env bash
set -uo pipefail

BIN="/Applications/AnyDesk.app/Contents/MacOS/AnyDesk"

log() { printf '[diag-anydesk] %s\n' "$*"; }

# Cek karakteristik password TANPA menampilkan nilainya.
pw_len="${#ANYDESK_PASSWORD}"
pw_lower=$(printf '%s' "$ANYDESK_PASSWORD" | grep -q '[a-z]' && echo yes || echo no)
pw_upper=$(printf '%s' "$ANYDESK_PASSWORD" | grep -q '[A-Z]' && echo yes || echo no)
pw_digit=$(printf '%s' "$ANYDESK_PASSWORD" | grep -q '[0-9]' && echo yes || echo no)
pw_special=$(printf '%s' "$ANYDESK_PASSWORD" | grep -q '[^a-zA-Z0-9]' && echo yes || echo no)
pw_space=$(printf '%s' "$ANYDESK_PASSWORD" | grep -q '[[:space:]]' && echo yes || echo no)

log "password  : length=$pw_len lowercase=$pw_lower uppercase=$pw_upper digit=$pw_digit special=$pw_special space=$pw_space"
log "CLI versi : $(timeout_bash 5 "\"$BIN\" --version" 2>/dev/null | head -1 || echo GAGAL)"
log "status    : $(timeout_bash 5 "\"$BIN\" --get-status" 2>/dev/null | head -1 || echo GAGAL)"

log "proses AnyDesk:"
pgrep -fl AnyDesk || true

# Jalankan `bash -c <cmd>` dengan batas waktu; kembalikan rc.
timeout_bash() {
  local secs="$1" cmd="$2" pid rc
  bash -c "$cmd" &
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

try_iteration() {
  local label="$1" cmd="$2" out rc txt
  out="$(mktemp)"
  bash -c "$cmd" >"$out" 2>&1 &
  local pid=$!
  local i
  for i in $(seq 1 5); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 1
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    rc=124
  else
    wait "$pid"; rc=$?
  fi
  txt="$(perl -pe "s/\Q$ANYDESK_PASSWORD\E/[REDACTED]/g" "$out")"
  rm -f "$out"
  log "  $label rc=$rc"
  if [ -n "$txt" ]; then
    log "  $label output: $txt"
  else
    log "  $label output: (kosong)"
  fi
}

log "Uji set-password (password di-redact):"
try_iteration "user+newline" 'printf "%s\n" "$ANYDESK_PASSWORD" | "$BIN" --set-password'
try_iteration "sudo+newline" 'printf "%s\n" "$ANYDESK_PASSWORD" | sudo -n "$BIN" --set-password'
try_iteration "user+arg    " '"$BIN" --set-password "$ANYDESK_PASSWORD"'
try_iteration "sudo+arg    " 'sudo -n "$BIN" --set-password "$ANYDESK_PASSWORD"'