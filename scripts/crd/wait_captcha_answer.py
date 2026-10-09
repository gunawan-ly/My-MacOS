#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
wait_captcha_answer.py — Tunggu jawaban CAPTCHA dari Awan via GitHub issue.

Dipanggil workflow setelah enroll.py keluar dengan kode 42 (CAPTCHA butuh jawaban).
Membaca nomor issue dari /tmp/crd-captcha-issue.txt, polling komentar,
lalu menulis jawaban ke /tmp/crd-captcha-answer.txt.

Exit 0 bila jawaban didapat, exit 1 bila timeout/gagal.
"""

import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import captcha_helper


def main():
    issue_file = "/tmp/crd-captcha-issue.txt"
    answer_file = "/tmp/crd-captcha-answer.txt"

    try:
        with open(issue_file) as f:
            issue_number = int(f.read().strip())
    except Exception as e:
        print("[wait-captcha] gagal baca nomor issue: %s" % e, file=sys.stderr)
        return 1

    print("[wait-captcha] polling issue #%d..." % issue_number, file=sys.stderr, flush=True)
    answer = captcha_helper.wait_for_issue_answer(issue_number, timeout_minutes=10)

    if answer:
        with open(answer_file, "w") as f:
            f.write(answer)
        captcha_helper.close_issue(issue_number, "Jawaban diterima, workflow lanjut. Terima kasih!")
        print("[wait-captcha] jawaban diterima.", file=sys.stderr, flush=True)
        return 0
    else:
        captcha_helper.close_issue(issue_number, "Timeout 10 menit, workflow dibatalkan.")
        print("[wait-captcha] timeout.", file=sys.stderr, flush=True)
        return 1


if __name__ == "__main__":
    sys.exit(main())
