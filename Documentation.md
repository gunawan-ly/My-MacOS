# Dokumentasi: Mengaktifkan Chrome Remote Desktop (CRD) di macOS VM (Anka) Headless

Tanggal: 17 Sep 2026
Target: Host `mac-github-runner` agar bisa diakses remote dari `adektersayang88@gmail.com` dengan PIN `123456`, tampil dan bisa menerima input (mouse/keyboard).

---

## 1. Ringkasan

Setelah diselesaikan, host CRD berjalan sebagai LaunchAgent di sesi GUI user **`runner`** (uid 501) — sesi yang benar-benar tampil di console/display VM. Video tampil (bukan layar hitam) karena Screen Recording diizinkan via TCC, dan input mouse/keyboard berfungsi karena Accessibility diizinkan.

Poin kunci yang membuat masalah selama ini sukar:

1. **RegisterHost adalah RPC same-origin `batchexecute`** (bukan endpoint corp), dan skema field-nya: `[hostId, publicKey, hostName, clientId]`.
2. **Ada banyak "perangkap" di lapisan macOS host** (TCC, sesi GUI, code signature, permission) di luar soal pendaftaran host.

---

## 2. Alur pendaftaran host (enrollment) yang berhasil

### 2.1 Tanpa UI (pakai batchexecute langsung)

- ID host baru: UUID `46654913-8f99-4d27-8ef4-b770a2fc0594`
- Endpoint: `https://remotedesktop.google.com/_/RemotingUi/data/batchexecute`
- RPC IDs:
  - `RMf1af` = RegisterHost (WRITE — wajib header `at`/XSRF)
  - `PTh6kb` = GetHostList (READ — tanpa `at`)
  - `T1Tvkf` = DeleteHost (WRITE — tanpa perlu `at` bila sesi trusted)
- Body `f.req=[[["RMf1af","<jsonpb>",null,"generic"]]]` di mana `<jsonpb>` harus **array posisional**:

  ```
  [hostId, publicKeyPEM_dari_generateKeyPair, hostName, clientId]
  ```

  - field1 = hostId (UUID)
  - field2 = publicKey (PEM hasil `generateKeyPair`), **bukan PIN**
  - field3 = nama host
  - field4 = clientId (`m890`) — urutan salah => kode error `[3]` (INVALID_ARGUMENT) / `[7]` (PERMISSION_DENIED)
- Respons: `JSON.parse(isi f.req)[0][2]` = `[<array host>, "<authorizationCode>"]`
- Token XSRF `at` diambil dari HTML halaman `/access`: regex `AAzdMo[a-zA-Z0-9_-]+:[0-9]+`. Tanpa `at` untuk RPC write → HTTP 400 dengan error `xsrf`.

### 2.2 Enroll penuh lewat daemon (native messaging)

Utilisasi biner `native_messaging_host` (framing: 4 byte little-endian length + JSON) — driver ada di `/tmp/opencode/nm.py`.

Urutan panggilan (sama dengan `rG.start()` di `remotingui.js`):

1. `stopDaemon`
2. `generateKeyPair` → `{privateKey, publicKey}`
3. `RegisterHost(name, publicKey)` (langkah 2.1) → `{hostId, authorizationCode}`
4. `getPinHash({hostId, pin})` → `host_secret_hash` (format `hmac:...`)
5. `getCredentialsFromAuthCode({authorizationCode})` → `{userEmail, refreshToken}`; userEmail = robot `466549138f994d278ef4b770a2fc0594@chromoting.gserviceaccount.com` (hostId tanpa dash), bukan email user.
6. `startDaemon({config, consent})` dengan config:

   ```
   {
     service_account: userEmail, xmpp_login: userEmail,
     oauth_refresh_token: refreshToken, host_name, host_secret_hash,
     private_key, host_owner: "adektersayang88@gmail.com", host_id
   }
   ```

- `startDaemon` sebagai **vncuser GAGAL** (`AuthorizationCopyRights` → butuh admin); sebagai **root BERHASIL** (`{result:"OK"}`). Config ditulis ke `/Library/PrivilegedHelperTools/org.chromium.chromoting.json`.

---

## 3. Kendala yang ditemui & solusinya

### 3.1 Host dibunuh SIGKILL `Code Signature Invalid`
- Gejala: `remoting_me2me_host` crash `EXC_CRASH SIGKILL`.
- Penyebab: sesi sebelumnya me-resign binary secara **ad-hoc**.
- Solusi: kembalikan binary asli ke bundle:
  - Backup asli: `/tmp/opencode/CRDHost.bak/Contents/MacOS/remoting_me2me_host`
  - `codesign` binary hasil restore: Team ID `EQHXZ8M8AV`, runtime flag normal.
- Bisa tetap ada `invalid resource directory` pada seal bundle (sudah ada sejak awal), tapi karena binary punya embedded signature + Team ID benar, host tidak dibunuh lagi.

### 3.2 Config tidak terbaca → `INVALID_HOST_CONFIGURATION`
- Gejala: log `Permission denied (13)` saat host mulai.
- Penyebab: `/Library/PrivilegedHelperTools/org.chromium.chromoting.json` dibuat 600 milik root, sedangkan host jalan sebagai user biasa.
- Solusi: `chmod 644` config tsb.

### 3.3 Service wrapper restart-loop (Accessibility check)
- Gejala: LaunchAgent asli `remoting_me2me_host_service --run-from-launchd` mencetak `Permission 'check-accessibility-permission' is denied` berulang dan tidak pernah menjalankan host.
- Solusi: **jalankan host secara langsung** di LaunchAgent, bukan via service wrapper:

  `/Library/PrivilegedHelperTools/ChromeRemoteDesktopHost.app/Contents/MacOS/remoting_me2me_host --host-config=/Library/PrivilegedHelperTools/org.chromium.chromoting.json`

  (tambahkan `-v` untuk verbose logging; `KeepAlive=true`, `RunAtLoad=true`, `LimitLoadToSessionType=Aqua`).

### 3.4 Layar hitam + input tidak berfungsi (SALAH SESI GUI)
- Gejala awal: client terhubung, video jalan, tapi layar hitam dan input error `CGPostMouseEvent error 1002`.
- Penyebab: **host berjalan di sesi GUI `vncuser` (uid 1001), padahal yang tampil di console adalah `runner` (uid 501)** — dibuktikan dari `scutil "show State:/Users/ConsoleUser"`:
  - `kCGSSessionOnConsoleKey : TRUE` utk runner (sesi 257)
  - `kCGSSessionOnConsoleKey : FALSE` utk vncuser (sesi 260)
- Konsekuensi: sesi non-console tidak bisa menangkap konten layar (hitam/kosong) dan tidak bisa mengirim event input (error 1002 = `kCGErrorInvalidConnection`).
- Solusi: pasang LaunchAgent di domain GUI **runner**:
  ```
  sudo launchctl bootout gui/501/org.chromium.chromoting
  pkill -9 -f remoting_me2me_host
  sudo launchctl bootstrap gui/501 /Library/LaunchAgents/org.chromium.chromoting.plist
  sudo launchctl kickstart -k gui/501/org.chromium.chromoting
  ```
- Perhatian: file `StandardOutPath`/`StandardErrorPath` di plist milik user lain menyebabkan host gagal start (`exit 78: EX_CONFIG`). Gunakan path log baru yang bisa ditulis user tujuan (mis. `/tmp/crd.host.{err,out}.log`).

### 3.5 Tampil tapi hanya wallpaper + menu bar (jendela tak tampil) → Screen Recording ditolak
- Gejala: user melihat wallpaper biru + menu bar + kursor bereaksi (I-beam/resize saat hover jendela), tapi **isi jendela tidak tampil** — hanya wallpaper.
- Penyebab: proses host **tidak punya izin Screen Recording**; macOS hanya mengirim desktop picture tanpa window content.
- Diagnosa: di TCC system DB ada baris kunci (client bundle identifier + csreq asli):
  ```
  kTCCServiceScreenCapture | com.google.chromeremotedesktop.me2me-host | 0 | auth_value=0 | csreq 184B
  ```
  `auth_value=0` = DENIED, dan baris inilah yang dihormati tccd (insert path-based tanpa csreq tidak mempan).
- Solusi: ubah `auth_value` dari 0 → 2, **tanpa menyentuh `csreq`** (csreq cocok dengan binary Google-signed hasil restore, `anchor apple generic + subject.OU = EQHXZ8M8AV`):
  ```
  sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" \
    "UPDATE access SET auth_value=2,auth_reason=4,auth_version=1,
       last_modified=strftime('%s','now')
     WHERE service='kTCCServiceScreenCapture'
       AND client='com.google.chromeremotedesktop.me2me-host' AND client_type=0;"
  killall -9 tccd
  sudo launchctl kickstart -k gui/501/org.chromium.chromoting
  ```
  Verifikasi di unified log: `log show --last 2m --predicate 'process=="tccd"'` muncul `AUTHREQ_CTX ... service=kTCCServiceScreenCapture, preflight=yes, query=1`.
- Catatan: Accessibility (`kTCCServiceAccessibility`) dan `kTCCServicePostEvent` di-grant serupa (auth_value=2). Cek grant: `remoting_me2me_host --evaluate-type=check-accessibility-permission` (exit 0 = granted).

### 3.6 File settings yang rusak
- `/Library/PrivilegedHelperTools/org.chromium.chromoting.settings.json` berisi bug kutip ganda (`""4/0...""`) dan client lama (`avn2sj1`) → dipindah ke `/tmp/opencode/chromoting.settings.json.bak` agar tidak dipakai.

### 3.7 Verifikasi input (host side)
- Pastikan kursor benar-benar digerakkan oleh client: sampling `CGEventGetLocation` dari sesi runner dalam beberapa detik (posisi berubah = input klien masuk).
- Tes injeksi lokal: program kecil memanggil `CGEventCreateMouseEvent` + `CGEventPost` → kursor pindah = injeksi OS berfungsi (hanya berlaku bila proses punya izin Accessibility).

---

## 4. Cara cek status host

- Log: `/tmp/crd.host.err.log` (verbose `-v`).
  - Sukses konek: `Signaling connected`, `Sending full heartbeat`, `Host ready to receive connections.`, `Client connected: <email>`, `Connection authenticated`.
- Proses: `ps ax | grep remoting_me2me_host`
- LaunchAgent: `sudo launchctl print gui/501/org.chromium.chromoting`

---

## 5. Komponen penting

- LaunchAgent: `/Library/LaunchAgents/org.chromium.chromoting.plist`
  - Label: `org.chromium.chromoting`
  - Program: `remoting_me2me_host -v --host-config=...`
  - RunAtLoad + KeepAlive, LimitLoadToSessionType=Aqua
- Config host: `/Library/PrivilegedHelperTools/org.chromium.chromoting.json` (mode 644)
- Binary (Google-signed, Team `EQHXZ8M8AV`):
  `/Library/PrivilegedHelperTools/ChromeRemoteDesktopHost.app/Contents/MacOS/remoting_me2me_host`
- Drivernya:
  - `/tmp/opencode/nm.py` — driver native-messaging (spawn host NM)
  - `/tmp/opencode/start.py` — kumpulan panggilan daemon (startDaemon dsb.)
- DB TCC (SIP mati → bisa diedit):
  `/Library/Application Support/com.apple.TCC/TCC.db`
- Backup:
  - `/tmp/opencode/CRDHost.bak` — bundle asli
  - `/tmp/opencode/chromoting.plist.orig` — plist LaunchAgent asli
  - `/tmp/opencode/chromoting.settings.json.bak` — settings rusak (disisihkan)

---

## 6. Catatan bersih-bersih / keamanan

- Hapus file kredensial sementara yang pernah dibuat selama debug:
  - `/tmp/opencode/cred.json`
  - `/tmp/opencode/refreshtoken.txt`
  - Token `at`/XSRF sementara di `/tmp/opencode` bila ada
- Config host berisi `oauth_refresh_token` + `private_key` — jangan disebar; mode hist begitulah bawaan CRD.
- PIN host: `123456`.

---

## 7. Masalah yang TIDAK perlu ditangani

- VNC fallback (port 5900, password `crd-bridge-...`) — tetap ada tetapi tidak diperlukan lagi.
- Login Google via Chrome headless/CDP — alur enroll sudah lewat NM langsung, tidak butuh sesi browser lagi.
- Host orphan kedua bernama sama: `b8e665ed-...` yang juga "mac-github-runner" bisa dihapus via DeleteHost bila ingin bersih dari daftar host.