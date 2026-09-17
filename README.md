# My-MacOS - Remote Access ke macOS GitHub Runner

Akses GUI/terminal ke runner **`macos-latest`** (GitHub-hosted macOS, ephemeral) secara remote.

## Status saat ini (2026-09-16)

- **VNC via Tailscale — AKTIF + GATE DISPLAY-OK/NO-DISPLAY.** Workflow **`macOS - VNC via Tailscale`**
  (`vnc-access.yml`) join ke tailnet, mengaktifkan Screen Sharing (legacy VNC) dengan password dari
  secret `VNC_PASSWORD`, lalu keep-alive. Koneksi + auth VNC selalu OK (`RFB 003.889`); apakah desktop
  tampil tergantung host: sebagian host pool **punya display** (terverifikasi E2E — gate
  `screencapture` 169KB + screenshot desktop asli Activity Monitor), sebagian **tidak punya
  framebuffer sama sekali** (WindowServer `-daemon`, `screencapture` gagal). `setup_vnc.sh` kini
  mencetak `DISPLAY-OK` / `NO-DISPLAY` eksplisit di log + baris `Display :` di blok `VNC READY`,
  sehingga tidak ada klaim semu. Client tetap **bVNC** (Android) lewat
  `vnc://runner@<ip-tailscale>:5900`; jika `NO-DISPLAY`, pakai SSH.
- **SSH via Tailscale — AKTIF & TERVERIFIKASI E2E.** Workflow **`macOS - SSH via Tailscale`**
  (`ssh-access.yml`) join ke tailnet kamu lalu mengaktifkan Remote Login (sshd), dan mencetak
  `ssh runner@<ip-tailscale>`. Login public key teruji konek dari luar (fingerprint key ikut dicetak
  di log untuk dicocokkan). Gunakan ini untuk inspeksi macOS dari dalam (debug CRD, dll).
- **Remote HP-ready — AKTIF & TERVERIFIKASI E2E (Termux, tanpa key).** Workflow
  **`macOS Remote (HP-ready)`** (`remote-tmate.yml`): bikin user `vncuser` (jalan pintas tembok
  SecureToken akun `runner`, adaptasi dari `dikeckaan/MacOS-Workflow-VNC`), 1 password untuk SSH +
  VNC, join tailnet. Login `vncuser` + password **teruji konek dari luar** (grup: admin,
  `access_ssh`, `access_screensharing). Lihat "Remote dari HP" di bawah. (ngrok/tmate dicoba dan
  dibuang: ngrok TCP butuh verifikasi kartu, DNS `*.tmate.io` diblokir di pool ini.)
- **CRD (Chrome Remote Desktop) — BELUM BERJALAN.** Ada kendala saat setup host (detail di
  bawah). Kode disimpan & siap dilanjutkan begitu cara bypass-nya ketemu — bisa dituntaskan dari
  dalam runner lewat SSH.

## Kendala CRD (kenapa belum jalan)

Trigger `Setup Chrome Remote Desktop` (run `35072181358`, macOS 26.6.2):

1. `brew install --cask chrome-remote-desktop-host` → **berhasil** ("CRD Host berhasil diinstall").
2. Tapi binary `remoting_start_host` **tidak ditemukan** di:
   - `/Applications/Chrome Remote Desktop.app/Contents/MacOS/remoting_start_host`
   - `/Applications/Chrome Remote Desktop Host.app/Contents/MacOS/remoting_start_host`
   - hasil `find /Applications /Library/PrivilegedHelperTools -name remoting_start_host` → kosong.

Isi `/Applications` setalah install cask: hanya ada **`Chrome Remote Desktop Host Uninstaller.app`**
(bukan host app).

**Kesimpulan sementara:** cask Homebrew `chrome-remote-desktop-host` hanya menginstall **service
host** (`.pkg` → LaunchAgent `org.chromium.chromoting` + helper tools di
`/Library/PrivilegedHelperTools`), tapi **tidak** menginstall binary `remoting_start_host` yang
berada di bundle aplikasi CRD (yang biasa diunduh dari halaman
remotedesktop.google.com/access / /headless).

**Hipotesis rencana lanjutan (setelah ada SSH):**
- inspeksi `pkgutil --files com.google.pkg.ChromeRemoteDesktopHost` untuk tahu file apa saja yang
  terpasang; dan/atau
- unduh DMG resmi (`https://dl.google.com/chrome-remote-desktop/chromeremotedesktop.dmg`), ekstrak,
  cari `remoting_start_host` di dalam `.pkg`/bundle, lalu jalankan auth headless
  (`--code ... --name ... --pin ... --redirect-url https://remotedesktop.google.com/_/oauthredirect`).

## Layar hitam VNC (akar masalah, hasil riset SSH 2026-09-16)

Investigasi dari dalam runner (`macos-latest`, macOS 26.6.2 ARM64, via SSH Tailscale) membuktikan
layar hitam **bukan** soal izin Screen Recording:

- `system_profiler SPDisplaysDataType` → kosong, `ioreg` tanpa `IODisplay`, **nol instance
  `IOFramebuffer`**, WindowServer jalan mode `-daemon` (`display: null`).
- `screencapture -x` → `could not create image from display`.
- TCC `ScreenCapture`/`Accessibility` justru **sudah granted** (SIP image ini disabled).
- VNC serve frame 1024x768 yang **hitam total** — Stack VNC-nya sehat, framebuffer-nya yang kosong.

Upaya virtual display via BetterDisplay (install + TCC grant + LaunchAgent `gui/501` + CLI
`create -devicetype=virtualscreen ...`): virtual screen **tercatat di prefs app** (`connected=1`,
ada ICC profile), tetapi WindowServer `-daemon` menolak (`Invalid display`, tanpa GPU/framebuffer)
sehingga tidak pernah online. Kesimpulan: desktop Aqua tidak bisa ditangkap di VM pool ini sampai
GitHub menyediakan display/GPU virtual. `setup_vnc.sh` sekarang punya **gate `check_framebuffer()`**
yang mencetak `DISPLAY-OK` / `NO-DISPLAY` eksplisit di log agar tidak ada klaim READY semu.
Untuk kerja terminal, pakai SSH (terverifikasi).

## Remote dari HP (Termux, tanpa key, tanpa password ribet)

Workflow **`macOS Remote (HP-ready)`** — cara pakai:

1. (Opsional) Isi input `password` saat Run workflow. Kosongkan = pakai secret `VNC_PASSWORD`.
   Password ini berlaku untuk **keduanya**: login SSH user `vncuser` + password VNC.
2. Buka Actions → **macOS Remote (HP-ready)** → Run workflow → tunggu blok `REMOTE READY` di log,
   catat IP-nya.
3. Di Termux (aplikasi Tailscale HP harus ON + login tailnet yang sama):
   ```
   pkg install openssh -y
   ssh vncuser@<ip-tailscale>
   ```
   Ketik password → ENTER → masuk. User `vncuser` adalah admin (bisa `sudo`, password sama).
4. VNC: bVNC → host `<ip-tailscale>:5900`, user `vncuser` (atau `runner`), password sama.
   Perhatikan baris `Display :` di log: `yes` = desktop tampil; `no` = host tak punya display
   (cancel + run ulang untuk host baru, atau cukup pakai SSH).

## SSH via Tailscale (sudah aktif)

Workflow **`macOS - SSH via Tailscale`** (`ssh-access.yml`) memberi akses terminal penuh ke runner:

```
GitHub Runner macOS (macos-latest)          Mac / HP kamu
  - install tailscale CLI                   - install Tailscale & login ke tailnet yang sama
  - join tailnet (node mac-<run_id>)        - ssh runner@<ip-tailscale>
  - aktifkan Remote Login (sshd)            - login: public key atau password
  - password runner di-set                  - langsung explorasi dari dalam
```

### Secret yang dibutuhkan (SSH)

| Nama | Jenis | Wajib? | Keterangan |
|---|---|---|---|
| `TAILSCALE_AUTHKEY` | Secret | Ya | Auth key dari https://login.tailscale.com/admin/settings/keys untuk tailnet kamu. |
| `MAC_USER_PASSWORD` | Secret | Opsional* | Password akun `runner` untuk login SSH (sudah ada; ≥8 karakter). |
| `SSH_PUBLIC_KEY` | Secret | Opsional* | Publik key (mis. `ssh-ed25519 AAAA...`) milik Mac kamu → login tanpa password. |

\* Setidaknya salah satu harus diisi agar bisa login: **public key lebih andal** di VM macOS
(mengubah password via `dscl` kadang ditolak tanpa SecureToken). Ambil pubkey kamu dari Mac:
`cat ~/.ssh/id_ed25519.pub` (atau `ssh-keygen -t ed25519` dulu bila belum punya) lalu
`gh secret set SSH_PUBLIC_KEY -R gunawan-ly/My-MacOS`.

### Cara pakai

1. Pastikan Mac kamu **login ke tailnet yang sama** (Tailscale app aktif, akun sama dengan pemilik
   `TAILSCALE_AUTHKEY`).
2. Buka Actions → **macOS - SSH via Tailscale** → Run workflow (opsional ubah `keep_alive_minutes`).
3. Lihat blok **`SSH READY`** di log step `Setup Tailscale + SSH` → paso `ssh runner@<ip>`.
4. Di terminal Mac: `ssh runner@<ip>` lalu jawab prompt password (atau key).

> Job berhenti otomatis (~maks 6 jam). VM ephemeral → IP & node tailnet baru tiap run.

## VNC via Tailscale (SUDAH AKTIF & TERVERIFIKASI)

Workflow **`macOS - VNC via Tailscale`** (`vnc-access.yml`) menyalakan **Screen Sharing** bawaan
macOS (legacy VNC, port `5900`) di runner — tanpa install app tambahan. Daemon `screensharingd`
di-spawn ulang otomatis oleh launchd (socket activation) setiap kali ada koneksi masuk, jadi port
5900 selalu siap meski daemon idle-exit setelah viewer terakhir putus.

```
GitHub Runner macOS (macos-latest)          HP / Mac kamu
  - join tailnet (node mac-<run_id>)        - install app Tailscale & login ke tailnet yang sama
  - kickstart: aktifkan Screen Sharing      - install app bVNC (Android; vnc:// militaris-style)
  - set password VNC = secret VNC_PASSWORD  - connect ke vnc://runner@<ip-tailscale>:5900
  - TCC: izin capture layar + keep awake    - masukkan password VNC_PASSWORD -> desktop tampil
```

### Secret yang dibutuhkan (VNC)

| Nama | Jenis | Wajib? | Keterangan |
|---|---|---|---|
| `TAILSCALE_AUTHKEY` | Secret | Ya | Auth key dari https://login.tailscale.com/admin/settings/keys untuk tailnet kamu. |
| `VNC_PASSWORD` | Secret | Ya | Password VNC (min 8 karakter, maks 8 karakter aktif yang dipakai VNC). |
| `SSH_PUBLIC_KEY` | Secret | Opsional* | Dipakai step Tailscale (agar bisa SSH inspeksi). |
| `MAC_USER_PASSWORD` | Secret | Opsional* | Password akun `runner` (fallback SSH). |

### Cara pakai (client)

1. **HP:** install **bVNC** (play store) + **Tailscale** (harus join ke tailnet yang sama dengan
   pemilik authkey, mis. akun Google yang sama).
2. Buka Actions → **macOS - VNC via Tailscale** → Run workflow.
3. Lihat blok **`VNC READY`** di log step `Setup VNC` → catat `Host : <ip>:5900`.
4. Di bVNC: **New Connection** → Host `<ip:5900>` (contoh `100.116.41.57:5900`) → username `runner`
   (bebas) → password = nilai secret `VNC_PASSWORD` → protocol: pilih **VNC/Apple** (server menawarkan
   Apple DH 30,33,36 + VNC autentikasi 2 — bVNC otomatis memilih yang cocok).
5. Desktop macOS muncul & bisa dikendalikan (15 detik setelah viewer terputus, daemon exit & menunggu
   koneksi baru — port tetap hidup via launchd).

> **Catatan:** RealVNC Viewer **tidak didukung** oleh Server ini (menolak protocol `RFB 003.889`
> Apple). Gunakan **bVNC** (Android) atau viewer lain yang menerima versi 3.889.

## Opsi CRD (disimpan)

Workflow **`macOS - Chrome Remote Desktop`** (`crd-access.yml`) membereskan mekanisme CRD headless:
install host, TCC izin layar, wake display, auth `remoting_start_host`, verifikasi, keep-alive.

### Cara kerja (saat sudah berfungsi)

```
KODE OAuth sekali pakai (dari remotedesktop.google.com/headless, mulai "4/")
                       |
                       v
GitHub Runner macOS (macos-latest)            HP / Laptop kamu
  - install Chrome Remote Desktop Host        - buka aplikasi Chrome Remote Desktop
  - remoting_start_host dengan kode + PIN     - login akun Google pemilik kode
  - host terdaftar ke akun Google kamu        - klik host (nama mac-<run_id>)
  - display dijaga menyala selama keep-alive  - masukkan PIN -> desktop tampil
```

Runner sifatnya **ephemeral**:

- VM baru setiap run → host CRD di akun kamu berubah-ubah (nama `mac-<run_id>`).
- Job berhenti otomatis setelah ~6 jam (limit GitHub untuk macos runner).

### Secret yang dibutuhkan (CRD)

| Nama | Jenis | Wajib? | Keterangan |
|---|---|---|---|
| `CRD_CODE` | Secret | Ya | Kode OAuth sekali pakai dari /headless (mulai `4/`, kadaluarsa cepat). |
| `CRD_PIN` | Secret | Ya | PIN koneksi (angka 6+ digit). |

> Kode `CRD_CODE` **sekali pakai & cepat kadaluarsa**. Setiap run harus ambil kode baru dari
> halaman headless dan perbarui secret, lalu trigger segera.

### Input workflow

| Nama | Wajib? | Keterangan |
|---|---|---|
| `hostname` | Tidak | Nama host di app CRD (default `mac-<run_id>`). |
| `keep_alive_minutes` | Tidak | Durasi job (default `355`, maks `355`). |

## Alur workflow (CRD)

**V1 (`crd-access.yml`, legacy):** `Checkout → Validate (CRD_CODE & CRD_PIN) → Setup CRD
(install host, TCC, display awake, auth headless, verifikasi) → Keep Alive`.

**V2 (`crd-access-v2.yml`, disarankan):** versi hasil perbaikan lapangan. Bedanya dengan V1:

1. **Install host dari DMG resmi** (`dl.google.com/chrome-remote-desktop`), bukan cask — karena
   cask TIDAK menyertakan `remoting_start_host` (akar kegagalan V1).
2. **Fix TCC layar yang benar** — V1 hanya INSERT baru; di lapangan layar tetap hitam karena baris
   ScreenCapture yang sudah ada (milik bundle id `com.google.chromeremotedesktop.me2me-host`
   berikut `csreq`) berstatus `auth_value=0` (DENIED). V2 melakukan **UPDATE `auth_value=2`
   sambil mempertahankan `csreq`**; bila baris belum ada, INSERT lengkap dengan `csreq` yang
   dihitung dari sertifikat binary (via Security framework).
3. **Sesi GUI on-console** — host dimuat via LaunchAgent langsung ke sesi yang benar-benar di
   console (di-parse dari `scutil show State:/Users/ConsoleUser` → `kCGSSessionOnConsoleKey`),
   bukan sesi latar / field `Name` yang menyesatkan. Sesi non-console = layar hitam + input err.
4. **Host dijalankan langsung** (`remoting_me2me_host -v --host-config=...`) dengan KeepAlive,
   bukan lewat service wrapper `--run-from-launchd` yang menolak akses.
5. **Verifikasi riil**: `Host ready to receive connections`, tangkapan layar (DISPLAY-CHECK),
   probe pointer (INPUT-CHECK).

## Susunan file

| File | Fungsi |
|---|---|
| `.github/workflows/ssh-access.yml` | Workflow SSH via Tailscale (validasi → join tailnet → Remote Login → keep-alive) |
| `.github/workflows/vnc-access.yml` | Workflow VNC via Tailscale (validasi → Tailscale → Screen Sharing → keep-alive) |
| `.github/workflows/crd-access.yml` | Workflow CRD V1 (legacy; cask tidak punya `remoting_start_host`) |
| `.github/workflows/crd-access-v2.yml` | Workflow CRD V2 (DMG resmi, TCC preserve-`csreq`, sesi on-console) |
| `scripts/ssh/tailscale_ssh.sh` | Install CLI Tailscale, `tailscaled` root, `tailscale up`, aktifkan sshd, set password/key, cetak `SSH READY` |
| `scripts/vnc/setup_vnc.sh` | kickstart Screen Sharing (legacy VNC), set password, TCC capture layar, launchd socket activation, cetak `VNC READY` |
| `scripts/crd/setup_crd.sh` | Setup CRD V1 (legacy) |
| `scripts/crd/setup_crd_v2.sh` | Setup CRD V2 (DMG, TCC update-preserve-`csreq`, LaunchAgent sesi on-console, verifikasi) |
| `scripts/keep_alive.sh` | Loop keep-alive sampai batas waktu (menampilkan `TSIP`/`CRD_NAME`/`VNC_HOST`) |

## Troubleshooting

- **`remoting_start_host tidak ditemukan`** (V1) → gunakan **V2**; cask tidak menyertakan binary
  tersebut, sementara DMG resmi memuatnya.
- **Layar hitam di klien** meski host online → izin ScreenCapture TCC ter-DENIED di baris bundle id
  + `csreq`. V2 menanganinya otomatis (UPDATE `auth_value=2`, `csreq` dipertahankan,
  `killall tccd` setelahnya). Verifikasi manual:
  `sudo sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" "SELECT service,client,auth_value FROM access WHERE client LIKE '%chromeremotedesktop%';"`
- **"CRD_CODE tidak valid"** → kode kadaluarsa/terpakai; ambil kode baru di halaman headless,
  perbarui secret, jalankan ulang.
- **Host tidak muncul di app CRD** → pastikan akun sama dengan yang membuat kode; tunggu ~15–60
  detik lalu refresh.
- **Runner lenyap** → VM ephemeral; setelah job selesai host ikut hilang.

## Security

- `TAILSCALE_AUTHKEY` hanya dari repo secret; node `mac-<run_id>` ikut masuk/keluar tailnet bersama
  job (ephemeral) — tidak membuka port publik.
- SSH mendukung login **public key** atau password; koneksi lewat tailnet terenkripsi.
- `CRD_CODE` adalah OAuth sekali pakai berumur pendek; `CRD_PIN` disimpan sebagai secret.
- Runner ephemeral: mesin & node tailnet/host CRD lenyap setelah job selesai.