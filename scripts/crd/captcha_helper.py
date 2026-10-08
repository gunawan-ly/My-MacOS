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


def create_status_issue(screenshot_path, note):
    """
    Buat issue status berisi screenshot halaman saat ini.
    Dipakai agar Awan langsung bisa melihat keadaan tanpa menunggu timeout.
    Return: nomor issue, atau None bila gagal.
    """
    run_id = os.environ.get("GITHUB_RUN_ID", "?")
    repo = os.environ.get("GITHUB_REPOSITORY", "")
    run_url = "https://github.com/%s/actions/runs/%s" % (repo, run_id)

    title = "Status login - run %s" % run_id
    body = (
        "Halo Awan! Ini screenshot keadaan halaman login di runner.\n\n"
        "**Status:** %s\n\n"
        "**Cara bantu (bila ada CAPTCHA di gambar):**\n"
        "1. Lihat gambar di bawah (atau buka artifact `crd-debug-%s` di [run ini](%s))\n"
        "2. Bila ada teks CAPTCHA terlihat, ketik sebagai **komentar** di issue ini\n"
        "3. Workflow akan otomatis lanjut setelah membaca komentarmu\n\n"
        "_Issue ini ditutup otomatis oleh workflow._"
        % (note, run_id, run_url)
    )
    log("membuat issue status...")
    try:
        issue = _gh_api("POST", "/issues", {"title": title, "body": body})
    except Exception as e:
        log("gagal buat issue: %s" % e)
        return None

    issue_number = issue.get("number")
    log("issue #%s dibuat" % issue_number)

    # Coba upload screenshot ke issue, update body bila berhasil
    img_md = _try_upload_image(issue_number, screenshot_path)
    if img_md:
        try:
            new_body = body.replace(
                "Lihat gambar di bawah",
                "Lihat gambar di bawah:\n\n%s\n" % img_md)
            _gh_api("PATCH", "/issues/%s" % issue_number, {"body": new_body})
        except Exception as e:
            log("gagal update body issue: %s" % e)

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
        "input[aria-label*='Type the text' i]",
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
    return None
