#!/usr/bin/env bash
set -uo pipefail

APP="/Applications/AnyDesk.app"
BIN="$APP/Contents/MacOS/AnyDesk"

log() { printf '[install-anydesk] %s\n' "$*"; }
fail() { printf '::error::%s\n' "$*" >&2; exit 1; }

log "Menginstall AnyDesk via Homebrew..."
brew update -q >/dev/null 2>&1 || true
brew install --cask anydesk || fail "Gagal menginstall AnyDesk via Homebrew."

[ -x "$BIN" ] || fail "Binary AnyDesk tidak ditemukan: $BIN"

log "Instalasi selesai: $BIN"
log "macOS $(sw_vers -productVersion) ($(uname -m))"