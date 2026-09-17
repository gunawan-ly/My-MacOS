# My-MacOS - Remote Access ke macOS GitHub Runner

Remote access GUI/terminal ke runner **`macos-latest`** (GitHub-hosted macOS, ephemeral) via
**Chrome Remote Desktop (CRD V2)** sebagai metode utama, dengan fallback **SSH via Tailscale**
untuk inspeksi terminal.

## Status saat ini (2026-09-17)

- **CRD V2 — AKTIF & TERVERIFIKASI.** Workflow `macOS - Chrome Remote Desktop (V2)`
  (`crd-access-v2.yml`): install host dari **DMG resmi** Google, perbaikan TCC layar
  (UPDATE `auth_value=2` sambil pertahankan `csreq`), sesi host on-console, autentikasi login
  Google (dirutekan via `enroll.py`) dengan **cache sesi cookie** agar job berikutnya **masuk
  tanpa login/OTP**, dan keep-alive. Host terdaftar ke akun `GOOGLE_USER` dan tampil di aplikasi
  CRD.
- **SSH via Tailscale — AKTIF (fallback).** Workflow `macOS - SSH via Tailscale` jaga akses
  terminal ke runner (join tailnet → Remote Login → login public key atau password).
- **Remote HP-ready (Termux) — AKTIF (fallback).** Workflow `macOS Remote (HP-ready)` memberi
  akses SSH/VNC satu password untuk HP.
- **VNC via Tailscale — DIPBUANG.** Infranya (`vnc-access.yml`, `scripts/vnc/`) sudah dihapus
  dari repo karena CRD V2 menjadi metode utama.

## Cara pakai CRD V2

1. Buka **Actions** → **macOS - Chrome Remote Desktop (V2)** → **Run workflow**.
2. Isi input (semua opsional di bawah memiliki default):
   - `hostname` — nama host di aplikasi CRD (default `mac-<run_id>`).
   - `keep_alive_minutes` — durasi job (default `355`, maks `355`).
   - `otp` — **security code** dari HP bila job pakai perangkat/login baru
     (Settings > Google > Manage Google Account > Security & sign-in > Security code).
     Kosongkan bila cache sesi masih sah → login tanpa OTP.
   - `session_mode` — `restore` (pakai cache terbaru; default) atau `fresh` (abaikan cache,
     paksa login+OTP sekali, simpan cookie baru).
   - `cache_key` — opsional; pin key cache spesifik (`crd-session-<email>-<run_id>`);
     kosong = pakai cache terbaru.
3. Tunggu blok `Host ready to receive connections` (dari log `Setup Chrome Remote Desktop (V2)`).
4. Buka aplikasi **Chrome Remote Desktop** (HP/PC) → klik host (nama dari `hostname`) →
   masukkan **PIN** (`CRD_PIN`) → desktop macOS muncul & bisa dikendalikan.

> **Penting:** dispatch uji harus dari **branch fitur** (jar `feat/cache-session-verification`)
> — `main` tidak lagi dipakai. Contoh:
> `gh workflow run crd-access-v2.yml -R gunawan-ly/My-MacOS --ref feat/cache-session-verification -f otp=<kode>`

## Secret yang dibutuhkan (CRD V2)

| Nama | Jenis | Wajib? | Keterangan |
|---|---|---|---|
| `GOOGLE_USER` | Secret | Ya | Email akun Google pemilik CRD (`guna040804@gmail.com`). |
| `GOOGLE_PASS` | Secret | Ya | Password akun tsb (dipakai bila restore cache tidak ada/fresh). |
| `CRD_PIN` | Secret | Ya | PIN koneksi (angka 6+ digit). |
| `CRD_OTP` | Secret | Opsional* | Security code sekali pakai; bisa diganti via input `otp`. |
| `CRD_SUDO_PASS` | Secret | Opsional** | Password sudo fallback (`run_sudo`). |
| `CRD_LOCAL_PASS` | Secret | Opsional** | Password sudo set lokal (fallback `run_sudo`). |
| `CRD_HELPER_USER` | Secret | Opsional*** | User pembantu admin utk prompt installer GUI. |
| `CRD_HELPER_PASS` | Secret | Opsional*** | Password user pembantu tsb. |

\* Hanya dibutuhkan pada run pertama/perangkat baru (saat Google minta verifikasi). Setelah itu
cache sesi yang disimpan otomatis membuat run berikutnya **tanpa login**.
\** Setidaknya satu dari `CRD_SUDO_PASS`/`CRD_LOCAL_PASS` atau NOPASSWD di host membuat sudo
berjalan non-interaktif (tanpa dialog GUI).
\*** Bila diisi, workflow membuat user `sysadminctl -addUser ... -admin` dengan password dikenal
untuk mengoper dialog password installer GUI (ganti username bawaan "Anka").

## Alur workflow CRD V2

`Validate Configuration` → `Provision user pembantu admin` (opsional) → `Restore Cache Sesi CRD`
(cookie Google; dilewati di mode `fresh`) → `Cek ketersediaan cache` → `Setup CRD (V2)`
(install DMG, TCC, kickstart host on-console, `enroll.py` login/restore + register, verifikasi) →
`Flag sesi segar` → `Save cache sesi` (always, kalau login OK) → `Upload Debug Artifacts` →
`Keep Alive`.

### Kenapa bisa login tanpa auth di job berikutnya

- `enroll.py` (CDP) membuka Chrome profil *fresh*. Bila ada cache sesi (manifest **v2**,
  `SCHEMA_VERSION=2`, guard akun, cookie expired dibuang) → cookie di-inject → `/access`
  langsung masuk.
- Cache disimpan ulang setiap run (key `crd-session-<user>-<run_id>`, restore-keys ber-prefiks
  user) hanya bila ada marker `/tmp/crd-session-fresh` (login benar-benar sukses; step Save pakai
  `always()` agar tersimpan walau langkah sesudahnya error).
- Bila cache tidak sah/expired → login penuh: Google akan minta verifikasi; isi input `otp`
  dengan security code dari HP.

## Troubleshooting CRD V2

- **Job pertama minta OTP terus** → sudah wajar; buka Google di HP (Settings > Google > Manage
  Google Account > Security & sign-in > Security code), isi code ke input `otp` saat dispatch,
  jalankan ulang. Setelah sukses, cache tersimpan & run berikutnya tanpa OTP.
- **Prompt password saat install (username "Anka")** → isi `CRD_HELPER_USER`+`CRD_HELPER_PASS`;
  workflow membuat user admin dgn password dikenal utk mengatasi dialog GUI.
- **Sudo menunggu password di GUI** → set salah satu dari `CRD_SUDO_PASS`/`CRD_LOCAL_PASS`, atau
  pastikan NOPASSWD aktif utk runner; `run_sudo` fail-fast tanpa dialog bila keduanya kosong.
- **Layar hitam di klien** → izin ScreenCapture TCC ter-DENIED; V2 memperbaikinya otomatis
  (UPDATE `auth_value=2` + pertahankan `csreq`, `killall tccd`). Verifikasi manual:
  `sudo sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" "SELECT service,client,auth_value FROM access WHERE client LIKE '%chromeremotedesktop%';"`
- **Host tidak muncul di app CRD** → pastikan akun = `GOOGLE_USER`; tunggu 15–60 detik; refresh.
- **Runner lenyap / IP baru** → VM ephemeral; host CRD & node tailnet ikut hilang saat job selesai.
- **Mode `fresh` tapi Google tolak browser** → browser terotomasi ditolak; gunakan `restore`
  dengan cache sah, atau tempel `otp`.

## Susunan file

| File | Fungsi |
|---|---|
| `.github/workflows/crd-access-v2.yml` | Workflow CRD V2 (satu-satunya CRD; maintanable dari branch fitur) |
| `.github/workflows/ssh-access.yml` | Workflow SSH via Tailscale (fallback) |
| `.github/workflows/remote-tmate.yml` | Workflow Remote HP-ready (Termux, fallback) |
| `scripts/crd/setup_crd_v2.sh` | Setup host CRD + sudo non-interaktif + TCC + kickstart on-console + verifikasi |
| `scripts/crd/enroll.py` | CDP Chrome: login/restore sesi cookie Google + register host (manifest v2) |
| `scripts/ssh/tailscale_ssh.sh` | Install CLI Tailscale, join tailnet, aktifkan sshd |
| `scripts/remote/setup_remote.sh` | Remote HP-ready (user `vncuser`, SSH password sama + VNC) |
| `scripts/keep_alive.sh` | Loop keep-alive sampai batas waktu |

## Security

- Semua secret hanya dari GitHub repo secrets; runner ephemeral (mesin & node tailnet/host CRD
  lenyap setelah job selesai).
- Tidak membuka port publik: akses lewat **tailnet** (SSH), auth CRD via akun Google + PIN.
- **Jangan commit cookie sesi / file kredensial ke repo (repo ini PUBLIC)** — sesi cookie hanya
  lewat GitHub Actions cache + restore manual. Lihat AGENTS.md untuk pedoman kerja.