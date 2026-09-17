# AGENTS.md

Pedoman kerja untuk agen (opencode/agent) di repo **My-MacOS**.

## Tujuan repo

Remote access GUI/terminal ke runner **`macos-latest`** (GitHub-hosted macOS, ephemeral) lewat
**Chrome Remote Desktop (CRD V2)**, plus fallback SSH via Tailscale.

## Branch policy (WAJIB)

- **Jangan pernah push ke `main`.** `main` dianggap rusak/legacy dan dibiarkan; workaround-nya
  (isi manual cache sesi) dipakai pengguna.
- Semua perubahan dikerjakan dan di-push **hanya di branch fitur**, mis.
  `feat/cache-session-verification`. Pakai branch fitur baru untuk perubahan independen.
- Dispatch uji workflow wajib lewat `--ref <branch-fitur>`.

## Perintah validasi (sebelum commit/push)

```bash
# Workflow lint (actionlint tidak bisa di-install via brew sebagai root; binary ada di /tmp)
/tmp/actionlint -no-color .github/workflows/crd-access-v2.yml

# YAML well-formed
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/crd-access-v2.yml'))"

# Python
python3 -m py_compile scripts/crd/enroll.py

# Shell (opsional, bila tersedia shellcheck)
shellcheck scripts/crd/setup_crd_v2.sh
```

## Alur CRD V2 (yang wajib dipahami)

- `crd-access-v2.yml` (dispatch) → `scripts/crd/setup_crd_v2.sh` → `scripts/crd/enroll.py`.
- `enroll.py` membuka Chrome profil *fresh* via CDP:
  1. `try_restore_session()`: bila ada cache sesi (`/tmp/crd-session-cookies.json`, manifest
     **v2**, `SCHEMA_VERSION=2`) yang sesuai akun → inject cookie → buka `/access` → **tanpa login/OTP**.
  2. Kalau tidak: `login_google()` penuh — di sinilah challenge Google (security code / device
     prompt / dsb.) terjadi.
- Cache disimpan kembali setiap run (`actions/cache/save`, key `crd-session-<user>-<run_id>`,
  `restore-keys` ber-prefiks user) hanya bila marker `/tmp/crd-session-fresh` ada (`always()` +
  `crd-fresh==1`). `CRD_CLEANUP=0` — **jangan pernah menghapus host lama**.

## Konvensi & pelajaran penting (jangan diregresi)

- **Step-level `if:` tidak boleh memakai `secrets` context** → pakai `env:` map ke secret lalu
  `if: env.X != ''`. Kalau dilanggar, workflow tidak valid & nama API jatuh ke path file.
- **`dscl . -passwd` / `-change` gagal sebagai root** pada akun admin (DS Error `-14090
  eDSAuthFailed`, rc=10) — jangan dipakai. Untuk password akun: `sysadminctl -addUser
  ... -password ... -admin` (buat baru, terverifikasi `dscl . -authonly`), `-resetPasswordFor`
  hanya best-effort (gagal tanpa SecureToken).
- **Prompt password installer GUI (dialog SecurityAgent)** → siapkan **user pembantu admin**
  dengan password dikenal via workflow (`CRD_HELPER_USER`/`CRD_HELPER_PASS`), dan saat dialog
  minta kredensial, ganti username bawaan ("Anka") dengan nilai secret tsb.
- **Sudo non-interaktif**: `run_sudo` di `setup_crd_v2.sh` memakai `sudo -n` → fallback
  `sudo -S` via `CRED_SUDO="${CRD_SUDO_PASS:-${CRD_LOCAL_PASS:-}}"` → fail-fast dengan pesan
  jelas; jangan biarkan dialog GUI password muncul.
- **OTP/security code**: jalur OOTP di `login_google` membaca `CRD_OTP`/`/tmp/crd.code` (input
  workflow `otp`). Tanpa kode → fail cepat + instruksi "KODE DIHP". Jangan tambah `die` instan
  untuk `mfa|otp|totp|sms|idv|securitykey` sebelum jalur kode dicoba. (Rencana "harden challenge"
  belum diimplementasi.)
- **Cookie sesi JANGAN pernah diekspor/di-commit ke repo** — repo ini **PUBLIC**; kredensial
  login Google = bocor. Sesi hanya boleh melalui GitHub Actions cache + restore manual user.
  (Pendekatan "bootstrap cookie dari profile Chrome" dibatalkan — keychain runner tak bisa
  di-unlock non-interaktif; `launchctl asuser` masih dapat `errKCInteractionNotAllowed`/keychain
  terkunci.)

## Inventory secret penting (repo gunawan-ly/My-MacOS; akun Google `guna040804@gmail.com`)

| Secret | Keterangan |
|---|---|
| `GOOGLE_USER` | Email pemilik CRD — `guna040804@gmail.com` |
| `GOOGLE_PASS` | Password akun tsb |
| `CRD_PIN` | PIN koneksi CRD (6+ digit) |
| `CRD_OTP` | Opsional; security code sekali pakai dari HP |
| `CRD_SUDO_PASS` / `CRD_LOCAL_PASS` | Password sudo fallback (`run_sudo`) |
| `CRD_HELPER_USER` / `CRD_HELPER_PASS` | User pembantu admin utk dialog installer GUI |
| `TAILSCALE_AUTHKEY`, `SSH_PUBLIC_KEY`, `MAC_USER_PASSWORD` | Fallback SSH/Remote |

## Susunan file aktif

- `.github/workflows/crd-access-v2.yml` — satu-satunya workflow CRD (V2).
- `.github/workflows/ssh-access.yml` & `remote-tmate.yml` + `scripts/ssh/`, `scripts/remote/`,
  `scripts/keep_alive.sh` — fallback akses (SSH/Termux).

## Sumber daya untuk dispatch uji

```bash
gh workflow run crd-access-v2.yml -R gunawan-ly/My-MacOS --ref feat/cache-session-verification \
  -f otp=<kode>             # hanya bila perangkat baru
  -f session_mode=restore   # atau 'fresh' utk paksa login baru
  -f cache_key=<key>        # opsional, pin cache spesifik
```