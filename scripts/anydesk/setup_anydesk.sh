#!/usr/bin/env bash
set -uo pipefail

APP="/Applications/AnyDesk.app"
BIN="$APP/Contents/MacOS/AnyDesk"

log() { printf '[setup-anydesk] %s\n' "$*"; }
fail() { printf '::error::%s\n' "$*" >&2; exit 1; }

# 1. Install via Homebrew
log "Installing AnyDesk via Homebrew..."
brew update -q >/dev/null 2>&1 || true
brew install --cask anydesk || fail "Gagal menginstall AnyDesk."

[ -x "$BIN" ] || fail "Binary AnyDesk tidak ditemukan: $BIN"

# 2. Launch aplikasi (sesi GUI runner user)
log "Meluncurkan AnyDesk..."
if ! open "$APP" 2>/dev/null; then
  log "open gagal, mencoba langsung dari binary..."
  "$BIN" >/dev/null 2>&1 &
fi

# 3. Tunggu service siap, polling sampai ID numerik diperoleh
ID=""
log "Menunggu AnyDesk service siap..."
for _ in $(seq 1 30); do
  ID="$("$BIN" --get-id 2>/dev/null | tr -d '[:space:]')"
  if [[ "$ID" =~ ^[0-9]{5,}$ ]]; then
    break
  fi
  ID=""
  sleep 2
done

if [ -n "$ID" ]; then
  log "AnyDesk ID: $ID"
else
  log "AnyDesk ID belum siap (status akan dicek pada langkah berikutnya)."
fi

# 4. Set password unattended access (nilai tidak pernah di-log)
if [ -n "${ANYDESK_PASSWORD:-}" ]; then
  log "Mengatur password unattended access..."
  if sudo -n true 2>/dev/null; then
    printf '%s' "$ANYDESK_PASSWORD" | sudo -n "$BIN" --set-password >/dev/null 2>&1
  else
    "$BIN" --set-password >/dev/null 2>&1 <<<"$ANYDESK_PASSWORD"
  fi
  sleep 2
  log "Password unattended access selesai dikonfigurasi."
fi

# 5. Alias opsional (dari repository/org variable)
if [ -n "${ANYDESK_ALIAS:-}" ]; then
  log "Mengatur alias jadi '$ANYDESK_ALIAS'..."
  "$BIN" --set-alias "$ANYDESK_ALIAS" >/dev/null 2>&1 || log "Alias gagal di-set (opsional)."
fi

# 6. Ekspos ID untuk step berikutnya
printf 'ANYDESK_ID=%s\n' "${ID:-UNKNOWN}" >> "$GITHUB_ENV"

log "Setup AnyDesk selesai."