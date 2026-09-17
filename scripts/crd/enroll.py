#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
enroll.py — Chrome Remote Desktop (CRD) headless enrollment untuk macOS runner.

Menggantikan peran binary `remoting_start_host` (yang TIDAK disertakan pada
paket CRD macOS; lihat Documentation.md) dengan tiga tahap yang terbukti:

  1. SESI BROWSER : buka Chrome (fresh profile) lewat CDP, login akun Google
     (GOOGLE_USER / GOOGLE_PASS), lalu petik cookie jar + token XSRF `at`
     dari halaman remotedesktop.google.com/access.
  2. REGISTER     : panggil RPC same-origin batchexecute `RMf1af`
     (RegisterHost) skema [hostId, publicKey, hostName, clientId]
     -> {hostId, authorizationCode} robot service-account.
  3. KONFIG       : lewat native_messaging_host -> generateKeyPair, getPinHash,
     getCredentialsFromAuthCode(authorizationCode) -> refreshToken robot.
     Output JSON config host ke stdout (di-install shell dengan mode 644).

Akar yang butuh izin akun tanpa 2FA; bila Google minta 2FA/challenge, skrip
berhenti dgn pesan jelas + screenshot debug di /tmp/crd-*.png.

Env: GOOGLE_USER, GOOGLE_PASS, CRD_PIN, CRD_NAME (opsional), GITHUB_RUN_ID.
Output stdout: JSON config host.
"""

import base64
import http.client
import json
import os
import re
import socket
import struct
import subprocess
import sys
import threading
import time
import urllib.parse
import urllib.request
import uuid

PORT = 9223
CLIENT_ID = "440925447803-m890isgsr23kdkcu2erd4mirnrjalf98.apps.googleusercontent.com"
SECRETS_OUT = "/tmp/crd-session.json"

CHROME_CANDIDATES = [
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/Applications/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing",
    "/Applications/Chromium.app/Contents/MacOS/Chromium",
]
NM_CANDIDATES = [
    "/Library/PrivilegedHelperTools/ChromeRemoteDesktopHost.app/Contents/MacOS/NativeMessagingHost.app/Contents/MacOS/native_messaging_host",
]


def log(*a):
    print("[enroll]", *a, file=sys.stderr, flush=True)


def die(msg):
    log("FATAL:", msg)
    sys.exit(1)


# ---------------------------------------------------------------------------
# Util file detection
# ---------------------------------------------------------------------------
def find_binary(env_key, candidates, glob_name):
    cand = os.environ.get(env_key)
    if cand and os.path.exists(cand):
        return cand
    for c in candidates:
        if os.path.exists(c):
            return c
    try:
        out = subprocess.run(
            ["find", "/Library/PrivilegedHelperTools", "/Applications",
             "-name", glob_name, "-type", "f"],
            capture_output=True, text=True, timeout=30).stdout
        for line in out.splitlines():
            if line.strip():
                return line.strip()
    except Exception:
        pass
    return None


def find_chrome():
    chrome = find_binary("CHROME_PATH", CHROME_CANDIDATES, "'Google Chrome'")
    if chrome:
        return chrome
    log("Chrome tidak ditemukan; fallback install brew cask google-chrome...")
    subprocess.run(["brew", "install", "--cask", "google-chrome"],
                   capture_output=True, text=True, timeout=600)
    return find_binary("CHROME_PATH", CHROME_CANDIDATES, "'Google Chrome'")


def find_nm():
    return find_binary("NM_HOST", NM_CANDIDATES, "native_messaging_host")


# ---------------------------------------------------------------------------
# WebSocket client minimal untuk CDP
# ---------------------------------------------------------------------------
class Ws:
    def __init__(self, url, timeout=30):
        self.url = url
        self.buf = b""
        self._id = 0
        self.sock = socket.create_connection(self._split(url), timeout=timeout)
        self._handshake(url)
        self.sock.settimeout(timeout)

    @staticmethod
    def _split(url):
        hostport, _, _ = url[len("ws://"):].partition("/")
        host, _, port = hostport.partition(":")
        return host, int(port or 80)

    def _handshake(self, url):
        hostport, _, path = url[len("ws://"):].partition("/")
        path = "/" + path
        host, _, port = hostport.partition(":")
        key = base64.b64encode(os.urandom(16)).decode()
        req = ("GET %s HTTP/1.1\r\nHost: %s:%s\r\nUpgrade: websocket\r\n"
               "Connection: Upgrade\r\nSec-WebSocket-Key: %s\r\n"
               "Sec-WebSocket-Version: 13\r\n\r\n") % (path, host, port, key)
        self.sock.sendall(req.encode())
        hdrs = b""
        while b"\r\n\r\n" not in hdrs:
            c = self.sock.recv(4096)
            if not c:
                raise RuntimeError("ws closed during handshake")
            hdrs += c
        if b" 101 " not in hdrs.split(b"\r\n", 1)[0]:
            raise RuntimeError("ws handshake failed: %r" % hdrs[:80])

    def _read(self, n):
        while len(self.buf) < n:
            c = self.sock.recv(4096)
            if not c:
                raise RuntimeError("ws read closed")
            self.buf += c
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def _recv_frame(self):
        while True:
            b0, b1 = self._read(2)
            op = b0 & 0x0F
            ln = b1 & 0x7F
            if ln == 126:
                ln = struct.unpack(">H", self._read(2))[0]
            elif ln == 127:
                ln = struct.unpack(">Q", self._read(8))[0]
            if b1 & 0x80:
                mask = self._read(4)
                payload = bytes(b ^ mask[i % 4] for i, b in enumerate(self._read(ln)))
            else:
                payload = self._read(ln)
            if op == 1:
                return payload.decode("utf-8", "replace")
            if op == 8:
                return None

    @staticmethod
    def _frame(payload):
        mask = os.urandom(4)
        ln = len(payload)
        if ln < 126:
            head = bytes([0x81, 0x80 | ln])
        elif ln < 65536:
            head = bytes([0x81, 0x80 | 126]) + struct.pack(">H", ln)
        else:
            head = bytes([0x81, 0x80 | 127]) + struct.pack(">Q", ln)
        return head + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(payload))

    def call(self, method, params=None, timeout=60):
        self._id += 1
        msg = {"id": self._id, "method": method, "params": params or {}}
        self.sock.sendall(self._frame(json.dumps(msg).encode()))
        self.sock.settimeout(timeout)
        while True:
            raw = self._recv_frame()
            if raw is None:
                raise RuntimeError("ws closed waiting response")
            obj = json.loads(raw)
            if obj.get("id") == self._id:
                if "error" in obj:
                    raise RuntimeError("CDP error: %s" % json.dumps(obj["error"])[:300])
                return obj.get("result", {})

    def close(self):
        try:
            self.sock.close()
        except Exception:
            pass


def cdp_connect():
    for _ in range(30):
        try:
            with urllib.request.urlopen("http://127.0.0.1:%d/json" % PORT, timeout=3) as r:
                targets = json.loads(r.read().decode())
            page = [t for t in targets if t.get("type") == "page"]
            if page:
                return Ws(page[0]["webSocketDebuggerUrl"])
        except Exception:
            pass
        time.sleep(1)
    raise RuntimeError("Chrome CDP tidak merespons di port %d" % PORT)


# ---------------------------------------------------------------------------
# Native messaging (framing: 4 byte little-endian length + JSON)
# ---------------------------------------------------------------------------
class NativeMessaging:
    def __init__(self, host_path, origin="chrome-extension://inomeogfingihgjfjlpeplalcfajhgai/"):
        args = [host_path] + ([origin] if origin else [])
        self.p = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, bufsize=0)
        self.lock = threading.Lock()
        self.errbuf = []
        threading.Thread(target=self._drain, daemon=True).start()

    def _drain(self):
        try:
            for line in iter(self.p.stderr.readline, b""):
                self.errbuf.append(line.decode("utf-8", "replace"))
        except Exception:
            pass

    def call(self, obj, timeout=60):
        data = json.dumps(obj).encode()
        with self.lock:
            self.p.stdin.write(struct.pack("<I", len(data)) + data)
            self.p.stdin.flush()
            self.p.stdout.settimeout(timeout)
            hdr = self._read_exact(4)
            if not hdr:
                raise RuntimeError("NM tidak membalas: %s" % "".join(self.errbuf[-3:]))
            n = struct.unpack("<I", hdr)[0]
            body = self._read_exact(n)
            if body is None:
                raise RuntimeError("NM respons terpotong")
            return json.loads(body.decode())

    def _read_exact(self, n):
        buf = b""
        while len(buf) < n:
            c = self.p.stdout.read(n - len(buf))
            if not c:
                return None
            buf += c
        return buf

    def close(self):
        try:
            self.p.stdin.close()
        except Exception:
            pass


# ---------------------------------------------------------------------------
# Chrome + login Google via CDP
# ---------------------------------------------------------------------------
def launch_chrome(chrome_path):
    profile = "/tmp/crd-chrome-%d" % os.getpid()
    os.makedirs(profile, exist_ok=True)
    args = [
        chrome_path,
        "--remote-debugging-port=%d" % PORT,
        "--user-data-dir=%s" % profile,
        "--no-first-run",
        "--no-default-browser-check",
        "--password-store=basic",
        "--use-mock-keychain",
        "--disable-component-update",
        "--disable-background-networking",
        "--disable-sync",
        "--no-service-autorun",
        "--disable-features=Translate,MediaRouter",
        "about:blank",
    ]
    proc = subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(2)
    return proc


def setup_page(page):
    for method, params in [("Page.enable", {}), ("Runtime.enable", {}), ("Network.enable", {})]:
        page.call(method, params)
    page.call("Page.addScriptToEvaluateOnNewDocument", {"source": """
Object.defineProperty(navigator, 'webdriver', { get: () => undefined });
Object.defineProperty(navigator, 'languages', { get: () => ['en-US', 'en'] });
window.chrome = window.chrome || { runtime: {} };
"""})
    page.call("Page.navigate", {"url": "about:blank"})


def js(page, expr, timeout=30):
    r = page.call("Runtime.evaluate", {"expression": expr, "returnByValue": True,
                                       "awaitPromise": True}, timeout=timeout)
    if "exceptionDetails" in r:
        raise RuntimeError("JS error: %s" % json.dumps(r["exceptionDetails"])[:400])
    inner = r.get("result", {})
    if inner.get("type") == "error":
        raise RuntimeError("JS error: %s" % json.dumps(inner)[:400])
    un = inner.get("unserializableValue")
    if un is not None:
        return un
    return inner.get("value")


def wait_until(page, expr, timeout=30, invert=False):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            v = js(page, expr, timeout=10)
            if bool(v) is not invert:
                return True
        except Exception:
            pass
        time.sleep(0.8)
    return False


def type_into(page, selector, value):
    ok = js(
        page,
        "(function(){"
        "var el=document.querySelector(%s);"
        "if(!el)return false;"
        "el.focus();"
        "el.click();"
        "el.value='';"
        "return true;"
        "})()" % json.dumps(selector),
        timeout=15
    )

    if not ok:
        raise RuntimeError("Element tidak ditemukan: %s" % selector)

    page.call("Input.dispatchKeyEvent", {
        "type": "keyDown",
        "key": "a",
        "code": "KeyA",
        "modifiers": 2
    })
    page.call("Input.dispatchKeyEvent", {
        "type": "keyUp",
        "key": "a",
        "code": "KeyA",
        "modifiers": 2
    })

    page.call("Input.insertText", {"text": value})

    js(
        page,
        "(function(){"
        "var el=document.querySelector(%s);"
        "if(!el)return false;"
        "el.dispatchEvent(new InputEvent('input',{"
        "bubbles:true,"
        "inputType:'insertText',"
        "data:null"
        "}));"
        "el.dispatchEvent(new Event('change',{bubbles:true}));"
        "return true;"
        "})()" % json.dumps(selector),
        timeout=15
    )

def click_login_button(page):
    selector = """
    (function(){
        var candidates = [
            '#identifierNext',
            '#passwordNext',
            'button[type="submit"]',
            'input[type="submit"]',
            '[role="button"][jsname="LgbsSe"]',
            '[role="button"][jsname="M2vV3"]',
            '[role="button"]'
        ];

        for (var s of candidates) {
            var els = document.querySelectorAll(s);

            for (var el of els) {
                var text = (el.innerText || el.getAttribute('aria-label') || '').trim();

                if (
                    s !== '[role="button"]' ||
                    /^(Next|Berikutnya|Continue|Lanjut)$/i.test(text)
                ) {
                    var r = el.getBoundingClientRect();

                    if (
                        r.width > 0 &&
                        r.height > 0 &&
                        !el.disabled
                    ) {
                        return {
                            x: r.left + r.width / 2,
                            y: r.top + r.height / 2,
                            text: text,
                            selector: s
                        };
                    }
                }
            }
        }

        return null;
    })()
    """

    target = js(page, selector, timeout=15)

    if not target:
        return False

    log(
        "klik tombol login: %s (%s,%s)"
        % (
            target.get("text", ""),
            target["x"],
            target["y"]
        )
    )

    page.call(
        "Input.dispatchMouseEvent",
        {
            "type": "mousePressed",
            "x": float(target["x"]),
            "y": float(target["y"]),
            "button": "left",
            "clickCount": 1
        }
    )

    page.call(
        "Input.dispatchMouseEvent",
        {
            "type": "mouseReleased",
            "x": float(target["x"]),
            "y": float(target["y"]),
            "button": "left",
            "clickCount": 1
        }
    )

    return True


def click(page, selector):
    return bool(js(page, "(function(){var el=document.querySelector(%s);if(!el)return false;"
                         "el.click();return true;})()" % json.dumps(selector), timeout=15))


def press_enter(page):
    page.call("Input.dispatchKeyEvent", {"type": "keyDown", "key": "Enter", "code": "Enter",
                                         "text": "\r", "unmodifiedText": "\r",
                                         "windowsVirtualKeyCode": 13, "nativeVirtualKeyCode": 13})
    page.call("Input.dispatchKeyEvent", {"type": "keyUp", "key": "Enter", "code": "Enter",
                                         "windowsVirtualKeyCode": 13, "nativeVirtualKeyCode": 13})


def click_center(page, selector):
    rect = js(page, "(function(){var el=document.querySelector(%s);if(!el)return null;"
                    "el.scrollIntoView({block:'center'});var b=el.getBoundingClientRect();"
                    "return {x:b.x+b.width/2,y:b.y+b.height/2};})()" % json.dumps(selector), timeout=15)
    if not rect:
        return False
    for t in ("mousePressed", "mouseReleased"):
        page.call("Input.dispatchMouseEvent", {"type": t, "x": float(rect["x"]), "y": float(rect["y"]),
                                               "button": "left", "clickCount": 1})
    return True


def screenshot(page, tag):
    try:
        r = page.call("Page.captureScreenshot", {"format": "png"})
        path = "/tmp/crd-%s-%d.png" % (tag, int(time.time()))
        with open(path, "wb") as f:
            f.write(base64.b64decode(r["data"]))
        log("screenshot debug -> %s" % path)
    except Exception as e:
        log("! screenshot gagal: %s" % e)


def dump_state(page, tag):
    """Cetak keadaan halaman saat ini (URL, title, DOM, input, iframe) utk debug."""
    def ev(expr):
        try:
            return js(page, expr, timeout=8)
        except Exception as e:
            return "ERR %s" % e
    info = {
        "url": ev("location.href"),
        "title": ev("document.title"),
        "readyState": ev("document.readyState"),
        "html_len": ev("document.documentElement ? document.documentElement.outerHTML.length : -1"),
        "body_snippet": ev("document.body ? document.body.innerText.slice(0, 400) : ''"),
        "inputs": ev("[...document.querySelectorAll('input')].map(i=>({type:i.type,name:i.name,id:i.id,ph:i.placeholder}))"),
        "iframes": ev("document.querySelectorAll('iframe').length"),
    }
    try:
        tree = page.call("Page.getFrameTree")
        info["frames"] = _flatten_frames(tree.get("frameTree", {}))
    except Exception as e:
        info["frames"] = "ERR %s" % e
    try:
        cookies = page.call("Network.getCookies", {"urls": ["https://accounts.google.com/"]}).get("cookies", [])
        info["cookie_names"] = [c.get("name") for c in cookies][:20]
    except Exception as e:
        info["cookie_names"] = "ERR %s" % e
    log("=== DEBUG %s ===" % tag)
    for k, v in info.items():
        log("  %s: %s" % (k, json.dumps(v)[:1600] if not isinstance(v, str) else str(v)[:1600]))


def _flatten_frames(ft):
    out = []

    def walk(node):
        if not node:
            return
        frame = node.get("frame") or {}
        out.append(frame.get("url", ""))
        for child in node.get("childFrames") or []:
            walk(child)

    walk(ft)
    return out


def login_google(page, user, password):
    continue_url = urllib.parse.quote(
        "https://remotedesktop.google.com/access",
        safe=""
    )

    url = (
        "https://accounts.google.com/ServiceLogin"
        "?hl=en&continue=%s"
        % continue_url
    )

    log("buka halaman login: accounts.google.com")
    page.call("Page.navigate", {"url": url})

    wait_until(
        page,
        "document.readyState !== 'loading'",
        30
    )

    email_selector = (
        "input[type=email],"
        "#identifierId,"
        "input[name=identifier],"
        "input[autocomplete=username]"
    )

    if not wait_until(
        page,
        "!!document.querySelector(%s)" % json.dumps(email_selector),
        120
    ):
        dump_state(page, "login-email")
        screenshot(page, "login-email")
        die(
            "Input email tidak muncul. "
            "Kemungkinan akun kena challenge/2FA/CAPTCHA."
        )

    log("mengisi email...")
    type_into(page, email_selector, user)

    time.sleep(1)

    current_email = js(
        page,
        "(function(){"
        "var e=document.querySelector(%s);"
        "return e ? e.value : '';"
        "})()" % json.dumps(email_selector),
        timeout=10
    )

    log(
        "email field terisi: %s"
        % ("OK" if current_email == user else "TIDAK SESUAI")
    )

    if current_email != user:
        dump_state(page, "email-not-filled")
        screenshot(page, "email-not-filled")
        die("Email gagal dimasukkan ke field Google.")

    if not click_login_button(page):
        press_enter(page)

    log("email dikirim; menunggu password...")

    password_selector = (
        "input[type=password],"
        "#password,"
        "input[name=Passwd],"
        "input[autocomplete=current-password]"
    )

    if not wait_until(
        page,
        "!!document.querySelector(%s)" % json.dumps(password_selector),
        60
    ):
        dump_state(page, "login-password")
        screenshot(page, "login-password")
        die(
            "Input password tidak muncul setelah email. "
            "Lihat DEBUG + screenshot."
        )

    log("mengisi password...")
    type_into(page, password_selector, password)

    time.sleep(1)

    password_ok = js(
        page,
        "(function(){"
        "var e=document.querySelector(%s);"
        "return !!(e && e.value && e.value.length > 0);"
        "})()" % json.dumps(password_selector),
        timeout=10
    )

    if not password_ok:
        dump_state(page, "password-not-filled")
        screenshot(page, "password-not-filled")
        die("Password gagal dimasukkan ke field Google.")

    log("password field terisi; submit login...")

    submitted = click_login_button(page)

    if not submitted:
        log("tombol Next tidak ditemukan; fallback Enter.")
        press_enter(page)

    deadline = time.time() + 120
    last_href = ""

    while time.time() < deadline:
        try:
            href = js(
                page,
                "location.href",
                timeout=10
            ) or ""

            body = str(
                js(
                    page,
                    "document.body ? "
                    "document.body.innerText.slice(0,1200) : ''",
                    timeout=10
                )
            )

            if href != last_href:
                log("login URL: %s" % href[:220])
                last_href = href

            # Berhasil menuju CRD.
            if href.startswith(
                "https://remotedesktop.google.com"
            ):
                log("login Google berhasil.")
                break

            # Password salah.
            if re.search(
                r"Wrong password|"
                r"Password yang salah|"
                r"Password salah|"
                r"Couldn't sign you in",
                body,
                re.I
            ):
                dump_state(page, "login-wrongpw")
                screenshot(page, "login-wrongpw")
                die(
                    "Google menolak password. "
                    "Periksa secret GOOGLE_PASS."
                )

            # Halaman login ditolak.
            if re.search(
                r"This browser or app may not be secure",
                body,
                re.I
            ):
                dump_state(page, "login-denied")
                screenshot(page, "login-denied")
                die(
                    "Google menolak browser terotomasi."
                )

            # Challenge MFA/OTP yang benar-benar aktif.
            challenge = re.search(
                r"/signin/challenge/(mfa|otp|totp|sms|"
                r"authenticator|securitykey|idv)",
                href,
                re.I
            )

            if challenge:
                dump_state(page, "login-2fa")
                screenshot(page, "login-2fa")
                die(
                    "Google meminta verifikasi tambahan "
                    "(2FA/challenge)."
                )

            # Masih berada di halaman password.
            if re.search(
                r"/signin/challenge/pwd",
                href,
                re.I
            ):
                if click_login_button(page):
                    log("submit password ulang via tombol Next.")
                else:
                    press_enter(page)

            time.sleep(2)

        except Exception as e:
            log("login-loop warning: %s" % str(e)[:250])
            time.sleep(2)

    else:
        dump_state(page, "login-loop")
        screenshot(page, "login-loop")
        die(
            "Login tidak selesai dalam 120 detik. "
            "Lihat DEBUG + screenshot."
        )

    log(
        "login OK -> %s"
        % (
            js(
                page,
                "location.href",
                timeout=10
            ) or ""
        )[:200]
    )

    page.call(
        "Page.navigate",
        {
            "url":
            "https://remotedesktop.google.com/access"
        }
    )

    if not wait_until(
        page,
        "document.readyState === 'complete'",
        60
    ):
        log(
            "Peringatan: /access belum complete setelah 60 detik."
        )


def grab_session(page):
    cookies = page.call("Network.getCookies", {"urls": ["https://remotedesktop.google.com/",
                                                        "https://accounts.google.com/"]}).get("cookies", [])
    if not cookies:
        die("Tidak ada cookie sesi Google (login gagal?)")
    jar = [{
        "name": c.get("name"), "value": c.get("value"),
        "domain": c.get("domain"), "path": c.get("path", "/"),
        "secure": bool(c.get("secure")), "httpOnly": bool(c.get("httpOnly")),
    } for c in cookies]
    html = js(page, "document.documentElement.outerHTML", timeout=30) or ""
    m = re.search(r"AAzdMo[a-zA-Z0-9_-]+:[0-9]+", html)
    if not m:
        try:
            with urllib.request.urlopen("https://remotedesktop.google.com/access", timeout=30) as r:
                html2 = r.read().decode("utf-8", "replace")
            m = re.search(r"AAzdMo[a-zA-Z0-9_-]+:[0-9]+", html2)
        except Exception:
            m = None
    if not m:
        die("Token XSRF `at` tidak ditemukan di /access. Login mungkin belum aktif penuh.")
    log("cookie sesi: %d cookie; at: %s..." % (len(jar), m.group(0)[:20]))
    return jar, m.group(0)


# ---------------------------------------------------------------------------
# RegisterHost via batchexecute
# ---------------------------------------------------------------------------
def register_host(jar, at, host_id, public_key, host_name):
    inner = json.dumps([host_id, public_key, host_name, CLIENT_ID])
    f_req = json.dumps([[["RMf1af", inner, None, "generic"]]])
    body = urllib.parse.urlencode({"f.req": f_req, "at": at})
    cookie = "; ".join("%s=%s" % (c["name"], c["value"]) for c in jar)
    conn = http.client.HTTPSConnection("remotedesktop.google.com", timeout=60)
    conn.request("POST", "/_/RemotingUi/data/batchexecute", body=body, headers={
        "Content-Type": "application/x-www-form-urlencoded;charset=UTF-8",
        "Cookie": cookie,
        "Referer": "https://remotedesktop.google.com/access",
    })
    resp = conn.getresponse()
    raw = resp.read().decode("utf-8", "replace")
    conn.close()
    if resp.status != 200:
        die("batchexecute HTTP %d: %s" % (resp.status, raw[:400]))

    text = raw.lstrip().replace(")]}'", "", 1).lstrip()
    blocks = []
    pos = 0
    while pos < len(text):
        nl = text.find("\n", pos)
        if nl < 0:
            break
        try:
            n = int(text[pos:nl].strip())
        except ValueError:
            break
        blocks.append(text[nl + 1:nl + 1 + n].strip())
        pos = nl + 1 + n
    for b in blocks:
        try:
            arr = json.loads(b)
            if (isinstance(arr, list) and arr and isinstance(arr[0], list)
                    and arr[0][:2] == ["wrb.fr", "RMf1af"]):
                result = json.loads(arr[0][2])
                host_info, auth_code = result[0], result[1]
                return host_info, auth_code
        except Exception:
            continue
    die("RegisterHost gagal di batchexecute. Output:\n%s" % raw[:600])


# ---------------------------------------------------------------------------
def main():
    user = os.environ.get("GOOGLE_USER", "").strip()
    password = os.environ.get("GOOGLE_PASS", "")
    pin = os.environ.get("CRD_PIN", "")
    name = os.environ.get("CRD_NAME", "mac-%s" % os.environ.get("GITHUB_RUN_ID", "runner")).strip()
    if "@" not in user:
        die("GOOGLE_USER harus berupa email.")
    if not password:
        die("GOOGLE_PASS kosong.")
    if not re.fullmatch(r"\d{6,}", pin):
        die("CRD_PIN harus 6+ digit.")
    if not name:
        die("CRD_NAME kosong.")

    host_id = str(uuid.uuid4())
    log("host_id tentatif: %s" % host_id)

    chrome = find_chrome()
    if not chrome:
        die("Chrome tidak tersedia. Set env CHROME_PATH bila perlu.")
    nm_path = find_nm()
    if not nm_path:
        die("native_messaging_host tidak ditemukan di /Library/PrivilegedHelperTools.")
    log("Chrome: %s" % chrome)
    log("NM: %s" % nm_path)

    proc = launch_chrome(chrome)
    page = None
    nm = None
    try:
        page = cdp_connect()
        setup_page(page)
        login_google(page, user, password)
        jar, at = grab_session(page)

        nm = NativeMessaging(nm_path)
        keys = nm.call({"type": "generateKeyPair"}, timeout=60)
        priv = keys.get("privateKey")
        pub = keys.get("publicKey")
        if not priv or not pub:
            die("generateKeyPair gagal: %s" % json.dumps(keys)[:300])

        host_info, auth_code = register_host(jar, at, host_id, pub, name)
        new_host_id = host_info[0] if isinstance(host_info, list) and host_info else host_id
        log("RegisterHost OK -> hostId=%s" % new_host_id)

        pin_hash = nm.call({"type": "getPinHash", "hostId": new_host_id, "pin": pin}, timeout=60)
        if "hash" not in pin_hash:
            die("getPinHash gagal: %s" % json.dumps(pin_hash)[:300])

        creds = nm.call({"type": "getCredentialsFromAuthCode",
                         "authorizationCode": auth_code}, timeout=120)
        if "refreshToken" not in creds:
            die("getCredentialsFromAuthCode gagal: %s" % json.dumps(creds)[:400])

        service_account = (creds.get("userEmail")
                           or new_host_id.replace("-", "") + "@chromoting.gserviceaccount.com")
        config = {
            "host_id": new_host_id,
            "host_name": name,
            "host_owner": user.lower(),
            "host_secret_hash": pin_hash["hash"],
            "private_key": priv,
            "service_account": service_account,
            "xmpp_login": service_account,
            "oauth_refresh_token": creds["refreshToken"],
            "usage_stats_consent": True,
        }
        with open(SECRETS_OUT, "w") as f:
            json.dump(config, f)
        print(json.dumps(config, indent=2), flush=True)
        log("SUKSES: config ditulis ke %s (host %s)" % (SECRETS_OUT, new_host_id))
    finally:
        try:
            if page:
                page.close()
        except Exception:
            pass
        try:
            if nm:
                nm.close()
        except Exception:
            pass
        try:
            proc.terminate()
        except Exception:
            pass
        time.sleep(1)
        try:
            proc.kill()
        except Exception:
            pass


if __name__ == "__main__":
    main()
