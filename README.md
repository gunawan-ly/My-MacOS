# My-MacOS - Remote Access to macOS GitHub Runner

Akses GUI runner **`macos-latest`** (GitHub-hosted macOS) secara remote via **Tailscale + Screen Sharing (VNC)**.

Runner macOS GitHub punya fitur native **Remote Login (SSH)** dan **Screen Sharing (VNC)**.
Kita mengaktifkannya dan menghubungkannya ke **tailnet** sehingga bisa diakses langsung dari perangkat kamu, tanpa membuka port publik.

## Cara kerja

```
PC CLIENT (Mac/Windows/Linux + VNC viewer)
  |
  v  (melalui tailnet, peer-to-peer)
Tailscale network (100.x.x.x)
  |
  v
GitHub Runner macOS (macos-latest, ephemeral)
  - tailscaled jalan di mode TUN
  - Screen Sharing (ARD) aktif, VNC legacy password di-set
  - password akun pengguna runner di-set
  - display dijaga tetap menyala selama keep-alive
  - alamat vnc://<tailscale-ip> dicetak di log / job summary
```

Runner sifatnya **ephemeral**:

- VM baru setiap run → **IP tailnet baru** tiap run (hostname `mac-<run_id>`).
- Job berhenti otomatis setelah ~6 jam (limit GitHub untuk macos runner).

## Mulai cepat (GitHub Actions)

1. Di repo ini: **Settings → Secrets and variables → Actions**.
   Tambahkan tiga secret:
   - `TAILSCALE_AUTHKEY` — auth key dari https://login.tailscale.com/admin/settings/keys.
   - `VNC_PASSWORD` — password VNC legacy, **maks. 8 karakter, tanpa spasi** (untuk klien VNC umum seperti Remmina/RealVNC).
   - `MAC_USER_PASSWORD` — password akun `runner` built-in (untuk login lewat Apple Screen Sharing), min. 8 karakter.
2. Buka tab **Actions** → pilih workflow **macOS - Remote Access (Tailscale + VNC)** → **Run workflow**.
   Input `keep_alive_minutes` default `355`. Centang `debug` bila ingin diagnosa tambahan.
3. Lihat log step **Print VNC Access Info** → blok `VNC READY` berisi alamat `vnc://<ip>`.
4. Konek dari perangkat kamu:
   - Mac: Finder → `Cmd+K` → `vnc://<ip>` → login `runner` + `MAC_USER_PASSWORD`.
   - Klien VNC lain (Remmina/RealVNC/TightVNC): host `<ip>` port `5900` → password `VNC_PASSWORD`.

> Catatan: Apple Screen Sharing biasanya meminta **akun macOS** (`runner` + `MAC_USER_PASSWORD`).
> Klien VNC non-Apple memakai **VNC legacy password** (`VNC_PASSWORD`).

## Konfigurasi (Variables & Secrets)

| Nama | Jenis | Wajib? | Keterangan |
|---|---|---|---|
| `TAILSCALE_AUTHKEY` | Secret | Ya | Auth key Tailscale untuk join tailnet. |
| `VNC_PASSWORD` | Secret | Ya | VNC legacy password untuk klien VNC umum (maks. 8 karakter, tanpa spasi). |
| `MAC_USER_PASSWORD` | Secret | Ya | Password akun `runner` untuk login Apple Screen Sharing (min. 8 karakter). |

## Susunan file

| File | Fungsi |
|---|---|
| `.github/workflows/macos-access.yml` | Workflow utama (Tailscale + VNC + keep-alive) |
| `scripts/remote/join_tailscale.sh` | Install CLI, jalankan `tailscaled` (TUN), `tailscale up`, simpan IP ke GITHUB_ENV |
| `scripts/remote/configure_vnc.sh` | Aktifkan Screen Sharing/ARD, set VNC password, set password akun, jaga display menyala |
| `scripts/remote/print_access_info.sh` | Cetak blok `VNC READY` + job summary |
| `scripts/keep_alive.sh` | Loop keep-alive sampai batas waktu |

## Alur workflow

Checkout → validasi secret → join tailnet → aktifkan Screen Sharing → cetak info akses → (diagnosa jika `debug`) → keep-alive.

## Security

- Password & auth key hanya dari GitHub Secrets (lewat env), tanpa membuka port publik.
- Koneksi lewat tailnet (peer-to-peer, terenkripsi); node `mac-<run_id>` otomatis masuk/keluar ikut kehadiran job.
- Runner ephemeral: mesin lenyap setelah job selesai.