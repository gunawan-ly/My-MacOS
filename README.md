# My-MacOS - Remote Access ke macOS GitHub Runner

Akses GUI/terminal ke runner **`macos-latest`** (GitHub-hosted macOS, ephemeral) secara remote.

## Status saat ini (2026-09-16)

- **CRD (Chrome Remote Desktop) — BELUM BERJALAN.** Ada kendala saat setup host (detail di
  bawah). Kode disimpan & siap dilanjutkan begitu cara bypass-nya ketemu.
- **Rencana berikutnya: SSH.** Kami akan menambahkan akses **SSH ke runner** supaya bisa
  menginspeksi langsung dari dalam macOS (mis. cari binary mau di mana, jalankan perintah),
  termasuk untuk menyelesaikan setup CRD. Rencananya memakai **tmate** (SSH publik instan,
  tanpa akun/port) atau **Tailscale** (SSH via tailnet).

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

`Checkout → Validate (CRD_CODE & CRD_PIN) → Setup CRD (install host, TCC, display awake,
auth headless, verifikasi) → Keep Alive`.

## Susunan file

| File | Fungsi |
|---|---|
| `.github/workflows/crd-access.yml` | Workflow CRD (validasi → setup host → keep-alive) |
| `scripts/crd/setup_crd.sh` | Install host, TCC izin layar, wake display, auth `remoting_start_host`, verifikasi |
| `scripts/keep_alive.sh` | Loop keep-alive sampai batas waktu |

## Troubleshooting

- **`remoting_start_host tidak ditemukan`** → status CRD saat ini; kemungkinan cask tidak menyertakan
  binary tersebut (lihat Kendala di atas). Perlu inspeksi dari dalam runner via SSH.
- **"CRD_CODE tidak valid"** → kode kadaluarsa/terpakai; ambil kode baru di halaman headless,
  perbarui secret, jalankan ulang.
- **Host tidak muncul di app CRD** → pastikan akun sama dengan yang membuat kode; tunggu ~15–60
  detik lalu refresh.
- **Runner lenyap** → VM ephemeral; setelah job selesai host ikut hilang.

## Security

- `crd_code` hanya OAuth sekali pakai berumur pendek; tidak disimpan permanen sebagai rahasia tetap.
- PIN koneksi disimpan sebagai repo secret (`CRD_PIN`).
- Akses ke host hanya lewat akun Google pemilik kode + PIN.
- Runner ephemeral: mesin dan host CRD lenyap setelah job selesai.