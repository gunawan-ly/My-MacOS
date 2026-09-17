#!/usr/bin/env bash
#
# setup_crd_v2.sh — Setup Chrome Remote Desktop (V2), berdasarkan temuan
# lapangan yang menggantikan setup_crd.sh lama:
#
#   1. Install host dari DMG resmi (cask homebrew TIDAK memuat remoting_start_host).
#   2. Registrasi headless via `remoting_start_host --code` (secret CRD_CODE).
#   3. Fix TCC layar (penyebab layar hitam): baris ScreenCapture yang sudah
#      ada adalah milik bundle id dengan csreq tapi auth_value=0 (DENIED).
#      Di sini dipakai UPDATE auth_value=2 sambil MENYIMPAN csreq — INSERT baru
#      tanpa csreq terbukti TIDAK berhasil di lapangan.
#   4. Host dijalankan LANGSUNG (bukan lewat service wrapper --run-from-launchd
#      yang menolak akses) pada sesi GUI yang AKTIF DI CONSOLE, KeepAlive,
#      log ke /tmp yang bisa ditulis user sesi.
#   5. Verifikasi riil: host siap, tangkapan layar berisi, input bergerak.
#
# Env (dari workflow / secret):
#   CRD_CODE - kode OAuth sekali pakai dari https://remotedesktop.google.com/headless
#   CRD_PIN  - PIN koneksi (angka 6+ digit)
#   CRD_NAME - nama host di aplikasi CRD (opsional)
#
set -uo pipefail

CRD_CODE="${CRD_CODE:-}"
CRD_NAME="${CRD_NAME:-mac-${GITHUB_RUN_ID:-runner}}"
CRD_PIN="${CRD_PIN:-}"
KEEP_ALIVE_MINUTES="${KEEP_ALIVE_MINUTES:-355}"

PLIST="/Library/LaunchAgents/org.chromium.chromoting.plist"
CONFIG_FILE="/Library/PrivilegedHelperTools/org.chromium.chromoting.json"
SETTINGS_FILE="/Library/PrivilegedHelperTools/org.chromium.chromoting.settings.json"
CRD_OUT_LOG="/tmp/crd.host.out.log"
CRD_ERR_LOG="/tmp/crd.host.err.log"
TCC_DB="/Library/Application Support/com.apple.TCC/TCC.db"
BUNDLE_ID="com.google.chromeremotedesktop.me2me-host"
DMG_URL="https://dl.google.com/chrome-remote-desktop/chromeremotedesktop.dmg"

log() { printf '[setup-crd-v2] %s\n' "$*"; }
die() { log "FATAL: $*"; exit 1; }

# Jalankan command dengan batas waktu (detik). stdout+stderr digabung & dicetak.
run_bounded() {
  local timeout_seconds=$1 rc out pid waited
  shift
  out="$(mktemp /tmp/crd.$$.out.XXXXXX)"
  bash -c "$*" >"$out" 2>&1 &
  pid=$!
  waited=0
  while [ "$waited" -lt "$timeout_seconds" ] && kill -0 "$pid" 2>/dev/null; do
    sleep 1; waited=$((waited + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; rc=124
  else
    wait "$pid"; rc=$?
  fi
  cat "$out"
  rm -f "$out"
  return "$rc"
}

# ---------------------------------------------------------------------------
# Deteksi komponen host
# ---------------------------------------------------------------------------
discover_host_bin() {
  find /Library/PrivilegedHelperTools /Applications \
    -name 'remoting_me2me_host' -type f 2>/dev/null | head -1
}

discover_start_host() {
  for c in \
    "/Applications/Chrome Remote Desktop.app/Contents/MacOS/remoting_start_host" \
    "/Applications/Google Chrome Remote Desktop.app/Contents/MacOS/remoting_start_host" \
    "/Applications/Chrome Remote Desktop Host.app/Contents/MacOS/remoting_start_host"; do
    [ -x "$c" ] && { printf '%s\n' "$c"; return 0; }
  done
  find /Library/PrivilegedHelperTools /Applications -name 'remoting_start_host' -type f 2>/dev/null | head -1
}

# ---------------------------------------------------------------------------
# Install host dari DMG resmi (memberikan remoting_start_host + host service)
# ---------------------------------------------------------------------------
install_host() {
  if [ -n "$(discover_start_host)" ]; then
    log "Host sudah terinstal (remoting_start_host ditemukan)."
    return 0
  fi

  log "Mengunduh DMG resmi: $DMG_URL"
  run_bounded 300 "curl -fSL --retry 3 -o /tmp/crd.dmg '$DMG_URL'" || die "Gagal mengunduh DMG CRD."
  [ -s /tmp/crd.dmg ] || die "DMG kosong/rusak."

  local mnt pkgs p
  mnt="$(mktemp -d /tmp/crd-mnt.XXXXXX)"
  hdiutil attach -nobrowse -mountpoint "$mnt" /tmp/crd.dmg >/dev/null 2>&1 || {
    rm -rf "$mnt"; die "Gagal mount DMG CRD."
  }
  pkgs="$(find "$mnt" -maxdepth 3 -name '*.pkg' 2>/dev/null)"
  [ -n "$pkgs" ] || {
    hdiutil detach "$mnt" >/dev/null 2>&1; rm -rf "$mnt"; die "Tidak ada .pkg di dalam DMG CRD."
  }
  for p in $pkgs; do
    log "Install pkg: $p"
    run_bounded 300 "sudo installer -pkg '$p' -target /" >/dev/null || log "Peringatan: installer gagal utk $p."
  done
  hdiutil detach "$mnt" >/dev/null 2>&1
  rm -rf "$mnt"

  if [ -z "$(discover_host_bin)" ]; then
    log "Host binary belum muncul; fallback ke cask homebrew."
    command -v brew >/dev/null 2>&1 \
      && run_bounded 300 "brew install --cask chrome-remote-desktop-host" >/dev/null || true
  fi

  local HB SH
  HB="$(discover_host_bin)"
  [ -n "$HB" ] || die "remoting_me2me_host tidak ditemukan setelah instalasi."
  SH="$(discover_start_host)"
  log "Host terinstal. remoting_start_host: ${SH:-(tidak ditemukan)}"
  if codesign -v "$HB" 2>/dev/null; then
    log "codesign OK: $(codesign -dv "$HB" 2>&1 | grep -m1 'Authority=')"
  else
    log "PERINGATAN: codesign host gagal verifikasi (host mungkin diubah; perlu binary asli Google, Team EQHXZ8M8AV)."
  fi
}

# Karantina settings.json korup/kedaluwarsa (klien OAuth lama / kutip ganda).
# File ini cache; host akan menulis ulang sendiri.
quarantine_settings() {
  if [ -f "$SETTINGS_FILE" ]; then
    local bak
    bak="${SETTINGS_FILE}.bak.$(date +%s)"
    sudo -n mv "$SETTINGS_FILE" "$bak" && log "settings.json lama dikarantina -> $bak"
  fi
}

# ---------------------------------------------------------------------------
# csreq (code requirement biner) dari binary, output hex — dipakai untuk baris
# TCC yang dikenali tccd (bundle id + csreq).
# ---------------------------------------------------------------------------
csreq_hex() {
  local bin="$1" py out rc
  py="$(mktemp /tmp/crd-csreq.XXXXXX.py)"
  cat > "$py" <<'PY'
import sys, ctypes, ctypes.util, binascii
p = sys.argv[1]
sec = ctypes.CDLL(ctypes.util.find_library('Security'))
cf = ctypes.CDLL(ctypes.util.find_library('CoreFoundation'))
cf.CFURLCreateFromFileSystemRepresentation.restype = ctypes.c_void_p
cf.CFURLCreateFromFileSystemRepresentation.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_long, ctypes.c_bool]
sec.SecStaticCodeCreateWithPath.restype = ctypes.c_int32
sec.SecStaticCodeCreateWithPath.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.POINTER(ctypes.c_void_p)]
sec.SecCodeCopyDesignatedRequirement.restype = ctypes.c_int32
sec.SecCodeCopyDesignatedRequirement.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.POINTER(ctypes.c_void_p)]
sec.SecRequirementCopyData.restype = ctypes.c_int32
sec.SecRequirementCopyData.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.POINTER(ctypes.c_void_p)]
cf.CFDataGetLength.restype = ctypes.c_long
cf.CFDataGetBytePtr.restype = ctypes.c_void_p
url = cf.CFURLCreateFromFileSystemRepresentation(None, p.encode(), len(p.encode()), False)
code = ctypes.c_void_p()
if sec.SecStaticCodeCreateWithPath(url, 0, ctypes.byref(code)) != 0:
    sys.exit(2)
req = ctypes.c_void_p()
if sec.SecCodeCopyDesignatedRequirement(code, 0, ctypes.byref(req)) != 0:
    sys.exit(2)
data = ctypes.c_void_p()
if sec.SecRequirementCopyData(req, 0, ctypes.byref(data)) != 0:
    sys.exit(2)
n = cf.CFDataGetLength(data)
ptr = cf.CFDataGetBytePtr(data)
buf = (ctypes.c_ubyte * n).from_address(ptr)
sys.stdout.write(binascii.hexlify(bytes(buf)).decode())
PY
  out="$(run_bounded 20 "python3 '$py' '$bin'" 2>/dev/null)"
  rc=$?
  rm -f "$py"
  [ "$rc" -eq 0 ] && [ -n "$out" ] && { printf '%s\n' "$out"; return 0; }
  return 1
}

# ---------------------------------------------------------------------------
# Fix baris TCC — kunci temuan lapangan:
#   * baris (service,client,client_type) SUDAH ADA  -> UPDATE auth_value=2,
#     TANPA menyentuh csreq (meng-update csreq ke NULL merusak izin).
#   * belum ada                                   -> INSERT lengkap (dgn csreq
#     bila berhasil dihitung), bukan INSERT kosong yang diabaikan tccd.
# ---------------------------------------------------------------------------
tcc_fix() {
  local svc="$1" client="$2" ctype="$3" csreq="$4"
  local qual exists ncols sql
  qual="service='$svc' AND client='$client' AND client_type=$ctype"

  exists="$(sudo -n sqlite3 "$TCC_DB" "SELECT 1 FROM access WHERE $qual LIMIT 1;" 2>/dev/null)"
  if [ -n "$exists" ]; then
    sudo -n sqlite3 "$TCC_DB" \
      "UPDATE access SET auth_value=2, auth_reason=4, auth_version=1, last_modified=strftime('%s','now') WHERE $qual;" \
      2>/dev/null
    log "  TCC UPDATE : $svc | $client (type=$ctype) [csreq dipertahankan]"
    return 0
  fi

  ncols="$(sudo -n sqlite3 "$TCC_DB" 'PRAGMA table_info(access);' 2>/dev/null | wc -l | tr -d ' ')"
  ncols="${ncols:-0}"
  if [ "$ncols" -gt 10 ]; then
    if [ -n "$csreq" ]; then
      sql="INSERT OR REPLACE INTO access (service,client,client_type,auth_value,auth_reason,auth_version,csreq,indirect_object_identifier,flags,last_modified) VALUES('$svc','$client',$ctype,2,4,1,X'$csreq','UNUSED',0,strftime('%s','now'));"
      log "  TCC INSERT dgn csreq : $svc | $client (type=$ctype)"
    else
      sql="INSERT OR REPLACE INTO access (service,client,client_type,auth_value,auth_reason,auth_version,indirect_object_identifier,flags,last_modified) VALUES('$svc','$client',$ctype,2,4,1,'UNUSED',0,strftime('%s','now'));"
      log "  TCC INSERT (no csreq): $svc | $client (type=$ctype)"
    fi
  else
    sql="INSERT OR REPLACE INTO access (service,client,client_type,auth_value,auth_reason,auth_version) VALUES('$svc','$client',$ctype,2,4,1);"
    log "  TCC INSERT skema lama : $svc | $client (type=$ctype)"
  fi
  sudo -n sqlite3 "$TCC_DB" "$sql" 2>/dev/null || log "  ! sqlite3 INSERT gagal: $svc | $client (type=$ctype)"
}

grant_tcc() {
  local HOST_BIN="$1" APP_BUNDLE csreq_h
  [ -x "$HOST_BIN" ] || HOST_BIN="$(discover_host_bin)"
  [ -n "$HOST_BIN" ] || die "Tidak ada remoting_me2me_host untuk TCC."

  APP_BUNDLE="${HOST_BIN%/*/Contents/MacOS/*}"
  case "$APP_BUNDLE" in *.app) ;; *) APP_BUNDLE='' ;; esac

  csreq_h="$(csreq_hex "$HOST_BIN")" || csreq_h=""
  log "csreq host: ${csreq_h:+OK ($(( ${#csreq_h} / 2 )) byte)}${csreq_h:-GAGAL dihitung}"
  csreq_h="$(tr -d '\n' <<<"${csreq_h:-}")"

  log "Menerapkan izin TCC utk host $BUNDLE_ID ..."
  for svc in ScreenCapture Accessibility PostEvent ListenEvent AppleEvents; do
    tcc_fix "$svc" "$BUNDLE_ID" 0 "$csreq_h"
  done
  tcc_fix ScreenCapture "$HOST_BIN" 1 "$csreq_h"
  tcc_fix Accessibility "$HOST_BIN" 1 "$csreq_h"
  tcc_fix PostEvent      "$HOST_BIN" 1 "$csreq_h"
  if [ -n "$APP_BUNDLE" ]; then
    for svc in ScreenCapture Accessibility PostEvent; do
      tcc_fix "$svc" "$APP_BUNDLE" 1 "$csreq_h"
    done
  fi

  log "Restart tccd agar izin baru terbaca..."
  sudo -n killall -9 tccd 2>/dev/null || log "(tccd belum jalan — normal)"
  sleep 3
}

# Sesi GUI TERAKTIF di console (bukan sesi latar). Host di sesi non-console
# => layar hitam + CGPostMouseEvent error.
# Catatan lapangan yang KRITIS:
#   - `scutil show State:/Users/ConsoleUser` -> field `Name`/`UID` adalah user
#     LOGIN TERAKHIR (bisa sesi LATAR, mis. vncuser/1001) — MENYESATKAN.
#   - Yang benar: di `SessionInfo`, sesi dengan `kCGSSessionOnConsoleKey : TRUE`
#     (mis. runner/501) yang menampilkan layar sungguhan.
#   - `stat /dev/console` juga tidak andal (di runner milik vncuser).
# Di sini kita parse `SessionInfo` dan pilih user dari sesi on-console.
console_user() {
  local out user
  out="$(scutil 2>/dev/null <<'EOF'
show State:/Users/ConsoleUser
EOF
)"
  user="$(awk '
    /^    [0-9]+ : <dictionary> \{/ { inblk=1; onc=""; usr=""; next }
    inblk && /kCGSSessionOnConsoleKey : TRUE/ { onc="yes" }
    inblk && /kCGSSessionUserNameKey : /     { usr=$NF; gsub(/"/,"",usr) }
    inblk && /^    \}/ { if (onc=="yes" && usr!="") { print usr; exit } inblk=0 }
  ' <<<"$out")"
  [ -n "$user" ] && { printf '%s\n' "$user"; return 0; }
  # Fallback aman: user yang menjalankan job (pada CI == sesi console).
  id -un
}

setup_launchagent() {
  local HOST_BIN="$1" U= LOGIN_SHELL_UID=
  U="$(console_user)"
  LOGIN_SHELL_UID="$(id -u "$U" 2>/dev/null)"
  [ -n "$LOGIN_SHELL_UID" ] || die "Tidak dapat menentukan uid dari $U."

  log "Sesi GUI aktif (console): $U (uid $LOGIN_SHELL_UID)"
  log "Meluncurkan host langsung di gui/$LOGIN_SHELL_UID (bukan gui/1001 sesi latar)."

  # Lepas agent lama di semua domain utk mencegah dobel/bertabrakan.
  for u in "$(id -un)" "$U"; do
    sudo -n launchctl bootout "gui/$(id -u "$u")/org.chromium.chromoting" 2>/dev/null || true
  done
  sudo -n launchctl bootout system/org.chromium.chromoting 2>/dev/null || true

  : > "$CRD_OUT_LOG" 2>/dev/null || true
  : > "$CRD_ERR_LOG" 2>/dev/null || true

  local PLIST_TMP
  PLIST_TMP="$(mktemp /tmp/crd.plist.XXXXXX)"
  cat > "$PLIST_TMP" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>org.chromium.chromoting</string>
    <key>LimitLoadToSessionType</key><string>Aqua</string>
    <key>ProgramArguments</key>
    <array>
        <string>$HOST_BIN</string>
        <string>-v</string>
        <string>--host-config=$CONFIG_FILE</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key><false/>
    </dict>
    <key>ProcessType</key><string>Interactive</string>
    <key>StandardOutPath</key><string>$CRD_OUT_LOG</string>
    <key>StandardErrorPath</key><string>$CRD_ERR_LOG</string>
</dict>
</plist>
EOF

  sudo -n install -o root -g wheel -m 644 "$PLIST_TMP" "$PLIST" || die "Gagal menulis $PLIST."
  rm -f "$PLIST_TMP"

  sudo -n launchctl bootstrap "gui/$LOGIN_SHELL_UID" "$PLIST" 2>/dev/null \
    || log "(bootstrap: sudah ter-load — normal, lanjut kickstart)"
}

bounce_host() {
  local U UID_U
  U="$(console_user)"; UID_U="$(id -u "$U")"
  log "Kickstart host di gui/$UID_U/org.chromium.chromoting (mulai bersih dgn izin baru)..."
  sudo -n launchctl kickstart -k "gui/$UID_U/org.chromium.chromoting" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Registrasi headless (dua jalur: --pin dulu, lalu interaktif via stdin)
# ---------------------------------------------------------------------------
register_host() {
  local SH="$1"
  [ -n "$SH" ] || die "remoting_start_host tidak ditemukan; tidak bisa registrasi headless."
  log "Registrasi headless host '$CRD_NAME' ke akun pemilik CRD_CODE ..."

  if run_bounded 120 \
     "'$SH' --code='$CRD_CODE' --redirect-url='https://remotedesktop.google.com/_/oauthredirect' --name='$CRD_NAME' --pin='$CRD_PIN'" \
     >/tmp/crd.start.log 2>&1; then
    log "Registrasi (jalur --pin) OK."
    return 0
  fi
  log "Jalur --pin gagal; coba interaktif via stdin (name, pin, pin)..."
  if run_bounded 120 \
     "printf '%s\n%s\n%s\n' '$CRD_NAME' '$CRD_PIN' '$CRD_PIN' | '$SH' --code='$CRD_CODE' --redirect-url='https://remotedesktop.google.com/_/oauthredirect' --name='$CRD_NAME'" \
     >/tmp/crd.start.log 2>&1; then
    log "Registrasi (jalur stdin) OK."
    return 0
  fi
  log "=== /tmp/crd.start.log (hasil registrasi) ==="
  cat /tmp/crd.start.log 2>/dev/null || true
  die "Registrasi headless gagal. CRD_CODE kedaluwarsa/terpakai? Ambil kode baru dan jalankan ulang."
}

wake_display() {
  log "Menyiapkan display (idle 0 + wallpaper + caffeinate)..."
  run_bounded 10 "osascript -e 'set idle time of application \"System Events\" to 0' -e 'tell application \"Finder\" to set desktop picture to POSIX file \"/System/Library/Desktop Pictures/Solid Colors/Blue.png\"'" >/dev/null 2>&1
  ( run_bounded 5 "caffeinate -dimsu" >/dev/null 2>&1 & ) || true
}

verify_host() {
  local HOST_BIN="$1" U UID_U i
  U="$(console_user)"; UID_U="$(id -u "$U")"
  log "Menunggu host siap (lihat $CRD_ERR_LOG)..."

  i=0; while [ "$i" -lt 30 ]; do
    if grep -m1 -q "Host ready to receive connections" "$CRD_ERR_LOG" 2>/dev/null; then
      log 'Host READY ("Host ready to receive connections" muncul).'
      break
    fi
    sleep 2; i=$((i + 1))
  done
  [ "$i" -lt 30 ] || log "Peringatan: tanda host-ready belum terlihat setelah 60 dtk (lihat log)."

  log "=== /tmp/crd.host.err.log (40 baris terakhir) ==="
  sudo -n tail -n 40 "$CRD_ERR_LOG" 2>/dev/null || tail -n 40 "$CRD_ERR_LOG" 2>/dev/null || true

  local sh sz
  sh="/tmp/crd-screencap-$(date +%s).png"
  run_bounded 20 "screencapture -x '$sh'" >/dev/null 2>&1 || true
  if [ -s "$sh" ]; then
    sz="$(sips -g pixelWidth -g pixelHeight "$sh" 2>/dev/null | awk '/pixel/ {printf "%s ", $2}')"
    rm -f "$sh"
    say_display "DISPLAY-CHECK: ${sz:-TIDAK-KETAHUI}"
  else
    say_display "DISPLAY-CHECK: NO-DISPLAY (pool tanpa framebuffer / WindowServer -daemon)"
  fi

  verify_input_notify
}

say_display() { printf '%s\n' "$*"; }

# Probe pointer: warp ke tengah layar, cek lokasinya bergeser (input OK).
verify_input_notify() {
  local py probe x1 y1 x2 y2
  py="$(mktemp /tmp/crd-input.XXXXXX.py)"
  cat > "$py" <<'PY'
import ctypes, ctypes.util, time, sys
lib = ctypes.CDLL(ctypes.util.find_library('ApplicationServices'))
class CGPoint(ctypes.Structure):
    _fields_ = [('x', ctypes.c_double), ('y', ctypes.c_double)]
lib.CGEventCreate.restype = ctypes.c_void_p
lib.CGEventGetLocation.argtypes = [ctypes.c_void_p]
lib.CGEventGetLocation.restype = CGPoint
lib.CGWarpMouseCursorPosition.argtypes = [CGPoint]
lib.CGWarpMouseCursorPosition.restype = ctypes.c_int32

def where():
    ev = lib.CGEventCreate(None)
    return lib.CGEventGetLocation(ev)

a = where()
lib.CGWarpMouseCursorPosition(CGPoint(960, 540))
time.sleep(0.4)
b = where()
print("%.0f,%.0f -> %.0f,%.0f" % (a.x, a.y, b.x, b.y))
sys.exit(0)
PY
  probe="$(run_bounded 20 "python3 '$py'" 2>/dev/null)" || probe=""
  rm -f "$py"
  if [ -n "$probe" ] && [[ "$probe" == *"->"* ]]; then
    x1="${probe%% *}"; x1="${x1%%,*}"; y1="${probe%% *}"; y1="${y1##*,}"
    x2="${probe##*->}"; x2="${x2%%,*}"; x2="${x2// /}"
    y2="${probe##*->}"; y2="${y2##*,}"; y2="${y2// /}"
    if [ "$x1" != "$x2" ] || [ "$y1" != "$y2" ]; then
      log "Input OK: pointer bergeser ($probe)."
      say_display "INPUT-CHECK: OK"
    else
      log "Pointer tidak bergeser ($probe)."
      say_display "INPUT-CHECK: STATIS"
    fi
  else
    say_display "INPUT-CHECK: TIDAK-UKUR"
  fi
}

# ---------------------------------------------------------------------------
main() {
  [ -n "$CRD_CODE" ] || die "CRD_CODE kosong."
  case "$CRD_CODE" in 4/*) ;; *) die "CRD_CODE harus mulai '4/'.";; esac
  [ -n "$CRD_PIN" ] || die "CRD_PIN kosong."
  command -v sqlite3 >/dev/null 2>&1 || die "sqlite3 tidak ada."
  command -v python3 >/dev/null 2>&1 || die "python3 tidak ada."

  log "=============================================="
  log " Chrome Remote Desktop V2 | name=$CRD_NAME"
  log "=============================================="

  install_host
  local HOST_BIN
  HOST_BIN="$(discover_host_bin)"
  quarantine_settings

  register_host "$(discover_start_host)"

  sudo -n chmod 644 "$CONFIG_FILE" 2>/dev/null && log "chmod 644 $CONFIG_FILE" \
    || log "! chmod 644 tidak berlaku (config mungkin belum ada) — akan dicek host."

  grant_tcc "$HOST_BIN"
  setup_launchagent "$HOST_BIN"
  bounce_host
  wake_display
  verify_host "$HOST_BIN"

  echo ""
  echo "=========================================================================="
  echo " CRD (V2) READY — cara koneksi:"
  echo "   1. Buka Chrome Remote Desktop (app/web) dgn akun pemilik CRD_CODE."
  echo "   2. Pilih host  : $CRD_NAME"
  echo "   3. Masukkan PIN: $CRD_PIN"
  echo "   Keep-alive    : ~$KEEP_ALIVE_MINUTES menit (sesuai batas job)."
  echo "=========================================================================="
}

main "$@"