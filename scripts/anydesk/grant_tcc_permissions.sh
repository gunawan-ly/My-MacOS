#!/usr/bin/env bash
set -uo pipefail

BUNDLE="${1:-com.philandro.anydesk}"

USER_DB="$HOME/Library/Application Support/com.apple.TCC/TCC.db"
SYSTEM_DB="/Library/Application Support/com.apple.TCC/TCC.db"

log() { printf '[grant-tcc] %s\n' "$*"; }

# Service yang dibutuhkan AnyDesk: view layar, control input, & file transfer.
SERVICES=(
  kTCCServiceAccessibility
  kTCCServiceScreenCapture
  kTCCServiceSystemPolicyAllFiles
  kTCCServicePostEvent
  kTCCServiceListenEvent
  kTCCServiceAppleEvents
  kTCCServiceRemoteDesktop
)

grant_to() {
  local db="$1" svc="$2"
  local ts sql

  ts="$(date +%s)"
  sql="INSERT OR REPLACE INTO access
    (service, client, client_type, auth_value, auth_reason, auth_version,
     csreq, policy_id, indirect_object_identifier_type, indirect_object_identifier,
     indirect_object_code_identity, flags, last_modified)
    VALUES
    ('$svc', '$BUNDLE', 0, 2, 4, 1,
     NULL, NULL, 0, 'UNUSED',
     NULL, 0, $ts);"

  # Coba tulis sebagai user dulu, fallback via sudo (runner macOS mengizinkan).
  if sqlite3 "$db" "$sql" >/dev/null 2>&1; then
    log "OK   $(basename "$db") [$svc] (user)"
    return 0
  fi
  if sudo --non-interactive sqlite3 "$db" "$sql" >/dev/null 2>&1; then
    log "OK   $(basename "$db") [$svc] (sudo)"
    return 0
  fi
  log "FAIL $(basename "$db") [$svc]"
  return 1
}

main() {
  local db svc

  for db in "$SYSTEM_DB" "$USER_DB"; do
    if [ ! -f "$db" ]; then
      log "SKIP $db (tidak ada)"
      continue
    fi
    for svc in "${SERVICES[@]}"; do
      grant_to "$db" "$svc" || true
    done
  done

  # Restart tccd agar perubahan langsung terbaca.
  log "Merestart tccd..."
  sudo --non-interactive launchctl kickstart -k system/com.apple.tccd >/dev/null 2>&1 \
    || sudo --non-interactive launchctl stop com.apple.tccd >/dev/null 2>&1 \
    || sudo --non-interactive pkill -9 tccd >/dev/null 2>&1
  launchctl kickstart -k "gui/$(id -u)/com.apple.tccd" >/dev/null 2>&1 || true
  sleep 3

  # Verifikasi: jumlah permission AnyDesk (auth_value=2) di user DB.
  if [ -f "$USER_DB" ]; then
    local granted
    granted="$(sqlite3 "$USER_DB" \
      "SELECT COUNT(*) FROM access WHERE client='$BUNDLE' AND auth_value=2;" \
      2>/dev/null || echo 0)"
    log "Verifikasi: $granted service(s) AnyDesk di-grant (user TCC)."
    if [ "$granted" -eq 0 ]; then
      echo "::warning::Tidak ada permission AnyDesk yang berhasil di-grant."
    fi
  fi
}

main "$@"