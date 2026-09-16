# My-MacOS - Remote Access to macOS GitHub Runner

Akses runner **`macos-latest`** (GitHub-hosted macOS) secara remote.

- **Opsi 1: AnyDesk** (aktif) - koneksi melalui relay AnyDesk, tanpa membuka port publik.
- Opsi berikutnya direncanakan masuk ke folder `scripts/<opsi>/` masing-masing.

## Cara kerja

```
PC CLIENT (AnyDesk di perangkat kamu)
  |
 koneksi via relay AnyDesk, cari "Address ID"
  v
GitHub Runner macOS (macos-latest, ephemeral)
  - AnyDesk diinstall & password unattended di-set
  - Address ID dicetak di log / job summary
```

Runner sifatnya **ephemeral**:

- VM baru setiap run, jadi **Address ID berubah tiap run**.
- Job berhenti otomatis setelah ~6 jam (limit GitHub untuk macos runner).

## Mulai cepat (GitHub Actions)

1. Di repo ini: **Settings → Secrets and variables → Actions**.
   Tambahkan secret `ANYDESK_PASSWORD` (wajib, min. 8 karakter).
   Opsional: variable `ANYDESK_ALIAS` untuk nama ramah Address ID.
2. Buka tab **Actions** → pilih workflow **macOS - AnyDesk (Opsi 1)** → **Run workflow**.
   Input `keep_alive_minutes` default `355`.
3. Lihat log step **Print AnyDesk Access Info** → blok `ANYDESK READY` berisi **Address ID**.
4. Di perangkat client: buka AnyDesk → ketik Address ID → **Accept and continue** → masukkan password dari secret `ANYDESK_PASSWORD`.

## Konfigurasi (Variables & Secrets)

| Nama | Jenis | Wajib? | Keterangan |
|---|---|---|---|
| `ANYDESK_PASSWORD` | Secret | Ya | Password unattended access AnyDesk (min. 8 karakter). Tidak pernah ditulis di repo/log. |
| `ANYDESK_ALIAS` | Variable | Tidak | Alias/nama ramah untuk Address ID. |

## Susunan file

| File | Fungsi |
|---|---|
| `.github/workflows/macos-anydesk.yml` | Workflow Opsi 1 (AnyDesk) |
| `scripts/anydesk/install_anydesk.sh` | Install AnyDesk via Homebrew |
| `scripts/anydesk/grant_tcc_permissions.sh` | Grant izin TCC macOS (layar, kontrol, FDA) sebelum launch |
| `scripts/anydesk/configure_anydesk.sh` | Launch (anti-hang), tunggu ID, set password & alias |
| `scripts/anydesk/print_access_info.sh` | Cetak blok `ANYDESK READY` + job summary |
| `scripts/keep_alive.sh` | Loop keep-alive sampai batas waktu |

## Alur workflow

Checkout → validasi secret → install → grant izin TCC → launch & konfigurasi AnyDesk → cetak info akses → keep-alive.

> Catatan: AnyDesk butuh izin macOS **Screen Recording** (lihat layar) dan **Accessibility** (control mouse/keyboard). Keduanya di-grant otomatis via TCC db sebelum AnyDesk dilaunch, supaya tidak ada dialog modal yang menggantungkan proses.

## Security

- Password hanya dari GitHub Secrets, lewat env, tidak pernah ditulis ke file/log.
- Tanpa membuka port publik; koneksi lewat relay resmi AnyDesk.
- Runner ephemeral: mesin lenyap setelah job selesai.