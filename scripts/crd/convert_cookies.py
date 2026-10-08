#!/usr/bin/env python3
"""Konversi cookie dari secret CRD_SESSION_COOKIES ke session file enroll.py.

Menerima dua format input (via env CRD_SESSION_COOKIES):
1. Format Cookie-Editor (dari extension browser):
   [{"domain":".google.com","name":"...","value":"...","path":"/",
     "secure":true,"httpOnly":true,"expirationDate":123,"sameSite":"lax",...}]
2. Format session file enroll.py langsung:
   {"saved_at":123,"cookies":[{...}]}

Output: /tmp/crd-session-cookies.json dalam format yang dibaca
enroll.py::_load_session_cookies().

Hanya cookie .google.com / .googleusercontent.com yang disimpan.
"""
import json
import os
import sys
import time

OUT = "/tmp/crd-session-cookies.json"


def norm_same_site(v):
    m = {"lax": "Lax", "strict": "Strict", "none": "None",
         "unspecified": "Unspecified", "no_restriction": "None"}
    if not v:
        return "Unspecified"
    s = str(v).strip()
    return m.get(s.lower(), s[:1].upper() + s[1:].lower() if s else "Unspecified")


def convert_cookie(c):
    d = str(c.get("domain", ""))
    name = c.get("name")
    if not name:
        return None
    if not (d.endswith(".google.com") or d == "google.com"
            or d.endswith(".googleusercontent.com")):
        return None
    out = {
        "name": name,
        "value": c.get("value", ""),
        "domain": d,
        "path": c.get("path", "/"),
        "secure": bool(c.get("secure", False)),
        "httpOnly": bool(c.get("httpOnly", False)),
        "sameSite": norm_same_site(c.get("sameSite")),
    }
    exp = c.get("expirationDate")
    if exp:
        try:
            out["expirationDate"] = float(exp)
        except (TypeError, ValueError):
            pass
    return out


def main():
    raw = os.environ.get("CRD_SESSION_COOKIES", "").strip()
    if not raw:
        print("CRD_SESSION_COOKIES kosong, lewati.", file=sys.stderr)
        return 0
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as e:
        print("CRD_SESSION_COOKIES bukan JSON valid: %s" % e, file=sys.stderr)
        return 1

    if isinstance(data, dict) and isinstance(data.get("cookies"), list):
        cookies_in = data["cookies"]  # sudah format session file
    elif isinstance(data, list):
        cookies_in = data  # format Cookie-Editor
    else:
        print("Format tidak dikenal (harus list atau {cookies:[...]}).",
              file=sys.stderr)
        return 1

    cookies = [k for k in (convert_cookie(c) for c in cookies_in) if k]
    if not cookies:
        print("Tidak ada cookie google.com yang valid.", file=sys.stderr)
        return 1

    with open(OUT, "w") as f:
        json.dump({"saved_at": int(time.time()), "cookies": cookies}, f)
    print("Cookie sesi ditulis: %d cookie -> %s" % (len(cookies), OUT))
    return 0


if __name__ == "__main__":
    sys.exit(main())
