#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
captcha_helper.py — Minta bantuan Awan memecahkan CAPTCHA Google via GitHub issue.

Alur:
  1. enroll.py mendeteksi CAPTCHA (kolom password tidak muncul).
  2. Helper ini membuat GitHub issue berisi screenshot CAPTCHA + link run.
  3. Helper polling komentar issue tiap 15 detik (timeout 10 menit).
  4. Awan membalas komentar berisi teks CAPTCHA.
  5. Helper mengembalikan teks jawaban ke enroll.py untuk diisi ke form.

Env yang dibutuhkan: GITHUB_TOKEN, GITHUB_REPOSITORY, GITHUB_RUN_ID.
"""

import json
import os
import subprocess
import sys
import time
import urllib.request
import urllib.parse


def log(*a):
    print("[captcha]", *a, file=sys.stderr, flush=True)


def _gh_api(method, path, data=None):
    """Panggil GitHub REST API memakai GITHUB_TOKEN."""
    token = os.environ.get("GITHUB_TOKEN", "")
    repo = os.environ.get("GITHUB_REPOSITORY", "")
    if not token or not repo:
        raise RuntimeError("GITHUB_TOKEN / GITHUB_REPOSITORY tidak tersedia")
    url = "https://api.github.com/repos/%s%s" % (repo, path)
    headers = {
        "Authorization": "Bearer %s" % token,
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
    }
    body = None
    if data is not None:
        body = json.dumps(data).encode("utf-8")
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=body, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read().decode("utf-8")
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        err_body = e.read().decode("utf-8", "replace")[:500]
        raise RuntimeError("GitHub API %s %s -> %d: %s" % (method, path, e.code, err_body))


def _try_upload_image(issue_number, png_path):
    """Coba upload screenshot langsung ke issue. Return markdown image atau ''."""
    token = os.environ.get("GITHUB_TOKEN", "")
    repo = os.environ.get("GITHUB_REPOSITORY", "")
    fname = os.path.basename(png_path)
    # Endpoint upload aset GitHub (dipakai UI web untuk lampiran issue).
    url = "https://uploads.github.com/repos/%s/issues/%s/assets?name=%s" % (
        repo, issue_number, urllib.parse.quote(fname))
    try:
        with open(png_path, "rb") as f:
            img = f.read()
        req = urllib.request.Request(
            url, data=img, method="POST",
            headers={
                "Authorization": "Bearer %s" % token,
                "Content-Type": "image/png",
                "Content-Length": str(len(img)),
            })
        with urllib.request.urlopen(req, timeout=60) as resp:
            result = json.loads(resp.read().decode("utf-8"))
        dl_url = result.get("browser_download_url", "")
        if dl_url:
            log("screenshot terupload ke issue")
            return "![captcha](%s)" % dl_url
    except Exception as e:
        log("upload gambar gagal (fallback ke link artifact): %s" % e)
    return ""


def write_job_summary_image(screenshot_path, caption):
    """
    Tulis screenshot ke job summary GitHub Actions sebagai base64 embedded image.
    Awan bisa langsung lihat di halaman run tanpa download artifact.
    Gambar di-resize dulu agar tidak terlalu besar.
    """
    summary_file = os.environ.get("GITHUB_STEP_SUMMARY", "")
    if not summary_file:
        log("GITHUB_STEP_SUMMARY tidak tersedia")
        return False
    if not screenshot_path or not os.path.exists(screenshot_path):
        log("screenshot tidak ditemukan: %s" % screenshot_path)
        return False
    try:
        import base64
        # Baca dan resize gambar agar base64 tidak terlalu besar (max ~500KB)
        with open(screenshot_path, "rb") as f:
            img_data = f.read()
        log("ukuran screenshot asli: %d bytes" % len(img_data))
        # Jika terlalu besar (>400KB), coba kompres via PIL bila tersedia
        if len(img_data) > 400 * 1024:
            try:
                from PIL import Image
                import io
                img = Image.open(screenshot_path)
                # Resize ke max 800px lebar
                w, h = img.size
                if w > 800:
                    img = img.resize((800, int(h * 800 / w)), Image.LANCZOS)
                buf = io.BytesIO()
                img.save(buf, format="PNG", optimize=True)
                img_data = buf.getvalue()
                log("screenshot di-resize: %d bytes" % len(img_data))
            except ImportError:
                log("PIL tidak tersedia, pakai gambar asli")
            except Exception as e:
                log("resize gagal: %s" % e)
        b64 = base64.b64encode(img_data).decode("ascii")
        log("base64 length: %d" % len(b64))
        # Gunakan markdown image dengan data URI (lebih kompatibel dari HTML)
        md = "\n\n### %s\n\n![captcha](data:image/png;base64,%s)\n" % (caption, b64)
        with open(summary_file, "a") as f:
            f.write(md)
        log("screenshot ditulis ke job summary (%s)" % summary_file)
        return True
    except Exception as e:
        log("gagal tulis job summary: %s" % e)
        import traceback
        traceback.print_exc()
        return False


def upload_screenshot_artifact(screenshot_path, artifact_name=None):
    """
    Upload screenshot sebagai artifact LANGSUNG dari dalam step yang berjalan,
    memakai Node.js @actions/artifact resmi. Artifact langsung terlihat di
    halaman run tanpa menunggu step selesai.
    Return True bila berhasil.
    """
    if not screenshot_path or not os.path.exists(screenshot_path):
        log("screenshot tidak ditemukan: %s" % screenshot_path)
        return False
    run_id = os.environ.get("GITHUB_RUN_ID", "manual")
    name = artifact_name or ("crd-captcha-%s" % run_id)
    script = os.path.join(os.path.dirname(os.path.abspath(__file__)), "upload_artifact.js")
    if not os.path.exists(script):
        log("upload_artifact.js tidak ditemukan")
        return False
    try:
        import subprocess
        r = subprocess.run(
            ["node", script, name, screenshot_path],
            cwd=os.path.dirname(script),
            capture_output=True, text=True, timeout=120)
        if r.returncode == 0:
            log("artifact '%s' diupload langsung" % name)
            return True
        else:
            log("upload artifact gagal: %s" % r.stderr[:300])
            return False
    except Exception as e:
        log("upload artifact error: %s" % e)
        return False


def upload_to_imgur(screenshot_path):
    """
    Upload screenshot ke Imgur (anonim). Return URL gambar atau None.
    CAPTCHA bukan data sensitif, jadi aman di-host sementara.
    """
    if not screenshot_path or not os.path.exists(screenshot_path):
        return None
    try:
        import subprocess
        # Client-ID publik untuk upload anonim
        r = subprocess.run(
            ["curl", "-s", "-m", "60", "-X", "POST",
             "-H", "Authorization: Client-ID 546c25a59c58ad7",
             "-F", "image=@%s" % screenshot_path,
             "https://api.imgur.com/3/image"],
            capture_output=True, text=True, timeout=90)
        data = json.loads(r.stdout)
        if data.get("success"):
            url = data["data"]["link"]
            log("screenshot diupload ke Imgur: %s" % url)
            return url
        else:
            log("Imgur gagal: %s" % str(data.get("data"))[:200])
            return None
    except Exception as e:
        log("Imgur error: %s" % e)
        return None


def create_status_issue(screenshot_path, note):
    """
    Buat issue status dengan link gambar CAPTCHA (via Imgur).
    Return: nomor issue, atau None bila gagal.
    """
    run_id = os.environ.get("GITHUB_RUN_ID", "?")
    repo = os.environ.get("GITHUB_REPOSITORY", "")
    run_url = "https://github.com/%s/actions/runs/%s" % (repo, run_id)

    # Upload screenshot ke Imgur agar langsung bisa dilihat dari HP
    imgur_url = upload_to_imgur(screenshot_path)
    if imgur_url:
        image_section = "**Lihat gambar CAPTCHA:**\n\n![captcha](%s)\n\n[Klik untuk perbesar](%s)" % (imgur_url, imgur_url)
    else:
        image_section = "**Lihat gambar CAPTCHA:** buka [job summary di run ini](%s)" % run_url
        # Fallback ke job summary
        write_job_summary_image(screenshot_path, "CAPTCHA - run %s" % run_id)

    title = "Status login - run %s" % run_id
    body = (
        "Halo Awan! Google menampilkan CAPTCHA saat login di runner.\n\n"
        "**Status:** %s\n\n"
        "%s\n\n"
        "**Cara bantu:**\n"
        "1. Lihat gambar CAPTCHA di atas\n"
        "2. Ketik teks yang terlihat sebagai **komentar** di issue ini\n"
        "3. Workflow akan otomatis lanjut setelah membaca komentarmu\n\n"
        "_Timeout: 10 menit. Issue ini ditutup otomatis oleh workflow._"
        % (note, image_section)
    )
    log("membuat issue status...")
    try:
        issue = _gh_api("POST", "/issues", {"title": title, "body": body})
    except Exception as e:
        log("gagal buat issue: %s" % e)
        return None

    issue_number = issue.get("number")
    log("issue #%s dibuat" % issue_number)
    return issue_number


def wait_for_issue_answer(issue_number, timeout_minutes=10):
    """
    Tunggu jawaban Awan di komentar issue yang sudah ada.
    Return: teks jawaban, atau None bila timeout/gagal.
    """
    if not issue_number:
        return None
    deadline = time.time() + timeout_minutes * 60
    seen_ids = set()
    try:
        existing = _gh_api("GET", "/issues/%s/comments?per_page=100" % issue_number)
        seen_ids = {c.get("id") for c in existing}
    except Exception:
        pass

    log("menunggu jawaban Awan di issue #%s (timeout %d mnt)..." % (issue_number, timeout_minutes))
    while time.time() < deadline:
        time.sleep(15)
        try:
            comments = _gh_api("GET", "/issues/%s/comments?per_page=100" % issue_number)
        except Exception as e:
            log("polling gagal: %s" % e)
            continue
        for c in comments:
            cid = c.get("id")
            if cid in seen_ids:
                continue
            seen_ids.add(cid)
            author = (c.get("user") or {}).get("login", "")
            text = (c.get("body") or "").strip()
            if "[bot]" in author or not text:
                continue
            for line in text.splitlines():
                line = line.strip()
                if line and not line.startswith(">") and not line.startswith("#"):
                    answer = line
                    break
            else:
                continue
            log("jawaban diterima dari @%s" % author)
            return answer
    log("timeout menunggu jawaban")
    return None


def close_issue(issue_number, message):
    """Tutup issue dengan pesan penutup."""
    if not issue_number:
        return
    try:
        _gh_api("POST", "/issues/%s/comments" % issue_number, {"body": message})
        _gh_api("PATCH", "/issues/%s" % issue_number, {"state": "closed"})
        log("issue #%s ditutup" % issue_number)
    except Exception as e:
        log("gagal tutup issue: %s" % e)


def request_captcha_answer(screenshot_path, timeout_minutes=10):
    """
    Kompatibilitas: buat issue lalu tunggu jawaban (gabungan dua fungsi).
    Return: teks jawaban, atau None bila timeout/gagal.
    """
    issue_number = create_status_issue(
        screenshot_path,
        "Google menampilkan CAPTCHA saat login di runner.")
    if not issue_number:
        return None
    answer = wait_for_issue_answer(issue_number, timeout_minutes)
    if answer:
        close_issue(issue_number, "Jawaban diterima, workflow lanjut. Terima kasih!")
    else:
        close_issue(issue_number, "Timeout %d menit, workflow dibatalkan." % timeout_minutes)
    return answer


def is_captcha_page(js_fn):
    """Deteksi halaman CAPTCHA Google via DOM. js_fn = fungsi js(page, expr)."""
    try:
        has_captcha_text = js_fn(
            "document.body && /Type the text you hear or see/i.test(document.body.innerText)",
            timeout=10)
        has_captcha_img = js_fn(
            "!!document.querySelector('img[src*=\"captcha\"], img[aria-label*=\"captcha\" i], #captchaimg')",
            timeout=10)
        return bool(has_captcha_text or has_captcha_img)
    except Exception:
        return False


def get_captcha_input_selector(js_fn):
    """Cari selector input CAPTCHA yang terlihat."""
    candidates = [
        "input[name='ca']",
        "input#ca",
        "input[name='captcha']",
        "input[id*='captcha' i]",
        "input[aria-label*='Type the text' i]",
        "input[aria-label*='captcha' i]",
        "input[placeholder*='Type the text' i]",
    ]
    for sel in candidates:
        try:
            visible = js_fn(
                "(function(){var el=document.querySelector(%s);"
                "if(!el)return false;var r=el.getBoundingClientRect();"
                "return r.width>0&&r.height>0;})()" % json.dumps(sel),
                timeout=10)
            if visible:
                return sel
        except Exception:
            continue
    # Fallback: cari input text yang terlihat (bukan email/password)
    try:
        fallback = js_fn(
            "(function(){"
            "var inputs=document.querySelectorAll('input[type=\"text\"],input:not([type])');"
            "for(var i=0;i<inputs.length;i++){"
            "var el=inputs[i];var r=el.getBoundingClientRect();"
            "if(r.width>0&&r.height>0&&el.type!=='email'&&el.type!=='password'){"
            "var idx=i;el.setAttribute('data-captcha-idx',idx);return 'input[data-captcha-idx=\"'+idx+'\"]';"
            "}}return null;})()",
            timeout=10)
        if fallback:
            return fallback
    except Exception:
        pass
    return None
