# My-MacOS - Chrome Remote Desktop on a macOS GitHub Runner

Akses GUI runner **`macos-latest`** (GitHub-hosted macOS, ephemeral) secara remote lewat **Google Chrome Remote Desktop** — dari HP (iOS/Android) atau desktop, pakai aplikasi CRD dan akun Google yang sama dengan pemilik kode.

Tidak perlu Tailscale, port forwarding, ngrok, atau VNC. Host CRD menembus NAT lewat relay/koneksi peer-to-peer Google.

## Cara kerja

```
KODE OAuth sekali pakai (dari remotedesktop.google.com/headless, mulai "4/")
                       |
                       v
GitHub Runner macOS (macos-latest)            HP / Laptop kamu
  - install Chrome Remote Desktop Host        - buka aplikasi Chrome Remote Desktop
  - remoting_start_host dengan kode + PIN     - login akun Google yang sama
  - host terdaftar ke akun Google kamu        - klik host (nama mac-<run_id>)
  - display dijaga menyala selama keep-alive  - masukkan PIN -> desktop tampil
```

Runner sifatnya **ephemeral**:

- VM baru setiap run → host di akun CRD kamu pun berubah-ubah (nama `mac-<run_id>`).
- Job berhenti otomatis setelah ~6 jam (limit GitHub untuk macos runner).

## Mulai cepat

1. Set **secret** `CRD_PIN` (repo → Settings → Secrets and variables → Actions):
   angka **6+ digit**, mis. `123456`. Dipakai untuk login koneksi (sama seperti PIN saat setup CRD biasa).

2. Buka **https://remotedesktop.google.com/headless** pakai akun Google kamu:
   - klik **Set up another computer** (Begin) → **Next** → **Authorize**.
   - salin **kode** di dalam tanda kutip dari command yang ditampilkan (mulai dengan `4/...`).

3. Jalankan workflow (Tab **Actions** → **macOS - Chrome Remote Desktop** → **Run workflow**):
   - `crd_code` → tempel kode dari langkah 2 (**berlaku singkat, ~beberapa menit** — jalankan segera).
   - `hostname` → opsional, nama host di app CRD (default `mac-<run_id>`).
   - `keep_alive_minutes` → default `355`.

4. Lihat log step **Setup Chrome Remote Desktop** → pesan `Selesai. Host '...' ...`.

5. Konek dari perangkat kamu:
   - Buka aplikasi **Chrome Remote Desktop** (atau web remotedesktop.google.com/access) dengan **akun Google yang sama**.
   - Di daftar **Remote Access**, ketuk host `mac-<run_id>` → masukkan **CRD_PIN** → Connect.

## Input & Secrets

| Nama | Jenis | Wajib? | Keterangan |
|---|---|---|---|
| `CRD_PIN` | Secret | Ya | PIN koneksi (angka 6+ digit). |
| `crd_code` | Input trigger | Ya | Kode OAuth sekali pakai dari /headless (mulai `4/`, kadaluarsa cepat). |
| `hostname` | Input trigger | Tidak | Nama host di app CRD (default `mac-<run_id>`). |
| `keep_alive_minutes` | Input trigger | Tidak | Durasi job (default `355`, maks `355`). |

> Kode `crd_code` **sekali pakai & cepat kadaluarsa**. Setiap run harus ambil kode baru dari halaman headless.

## Susunan file

| File | Fungsi |
|---|---|
| `.github/workflows/crd-access.yml` | Workflow CRD (validasi → setup host → keep-alive) |
| `scripts/crd/setup_crd.sh` | Install host, TCC izin layar, wake display, `remoting_start_host` (auth), verifikasi host |
| `scripts/keep_alive.sh` | Loop keep-alive sampai batas waktu |

## Alur workflow

Checkout → validasi (`crd_code` & `CRD_PIN`) → setup CRD (install host + LaunchAgent + TCC + display awake + registrasi ke akun) → keep-alive.

## Troubleshooting

- **Run gagal "crd_code tidak valid"** → kode kadaluarsa; ambil kode baru di halaman headless, jalankan ulang.
- **Host tidak muncul di app CRD** → pastikan login akun sama dengan yang membuat kode; tunggu ~15–60 detik lalu refresh.
- **Desktop hitam saat konek** → cek log step setup: baris `Screencapture test: N bytes` (N > 1000 = display OK). Kalau display OK tapi CRD hitam, kemungkinan isu rendering VM macOS 26; bisa dicoba ganti `runs-on` ke `macos-15` (image lama yang render normal).
- **Runner lenyap** → VM ephemeral; setelah job selesai host ikut hilang.

## Security

- `crd_code` hanya OAuth sekali pakai berumur pendek; dijalankan langsung saat trigger, tidak disimpan.
- PIN koneksi disimpan sebagai repo secret (`CRD_PIN`).
- Akses ke host hanya lewat akun Google pemilik kode + PIN.
- Runner ephemeral: mesin dan host CRD lenyap setelah job selesai.