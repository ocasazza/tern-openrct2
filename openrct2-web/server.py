#!/usr/bin/env python3
"""openrct2-web server: static www, RCT2 data files, and the agent bridge.

The page long-polls /bridge/next, answers via /bridge/result; agents POST /api.
"""
import argparse
import hashlib
import json
import mimetypes
import os
import select
import socket
import sys
import threading
import time
import uuid
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote, urlsplit

API_VERSION = "1"
RCT2_DIRS = ("Data", "ObjData", "Tracks", "Scenarios", "Landscapes")
POLL_TIMEOUT = 25.0
ALIVE_CHECK = 1.0
API_TIMEOUT = 60.0
CONNECTED_WINDOW = 5.0
MANIFEST_TTL = 30.0
MAX_API_BODY = 1 << 20
MAX_RESULT_BODY = 64 << 20

MIME = {
    ".wasm": "application/wasm",
    ".js": "text/javascript",
    ".mjs": "text/javascript",
    ".json": "application/json",
    ".html": "text/html; charset=utf-8",
    ".svg": "image/svg+xml",
    ".ico": "image/x-icon",
    ".zip": "application/zip",
}

SECURITY_HEADERS = (
    ("Cross-Origin-Opener-Policy", "same-origin"),
    ("Cross-Origin-Embedder-Policy", "require-corp"),
    ("Cross-Origin-Resource-Policy", "same-origin"),
    ("Cache-Control", "no-cache"),
)


class Bridge:
    """Request queue between /api callers and the polling page."""

    def __init__(self):
        self.cond = threading.Condition()
        self.queue = deque()
        self.waiters = {}
        self.active_polls = 0
        self.last_poll = 0.0

    def connected(self):
        with self.cond:
            return self._connected()

    def _connected(self):
        return self.active_polls > 0 or (time.monotonic() - self.last_poll) < CONNECTED_WINDOW

    def poll(self, timeout, alive):
        deadline = time.monotonic() + timeout
        with self.cond:
            self.active_polls += 1
            try:
                while not self.queue:
                    left = deadline - time.monotonic()
                    if left <= 0 or not alive():
                        return None
                    self.cond.wait(min(left, ALIVE_CHECK))
                return self.queue.popleft()
            finally:
                self.active_polls -= 1
                self.last_poll = time.monotonic()

    def submit(self, req, timeout):
        rid = uuid.uuid4().hex
        waiter = {"event": threading.Event(), "resp": None}
        with self.cond:
            if not self._connected():
                return None, "not_connected"
            self.waiters[rid] = waiter
            self.queue.append({"id": rid, "req": req})
            self.cond.notify()
        if not waiter["event"].wait(timeout):
            with self.cond:
                self.waiters.pop(rid, None)
                self.queue = deque(q for q in self.queue if q["id"] != rid)
            return None, "timeout"
        return waiter["resp"], None

    def resolve(self, rid, resp):
        with self.cond:
            waiter = self.waiters.pop(rid, None)
        if waiter is None:
            return False
        waiter["resp"] = resp
        waiter["event"].set()
        return True


class Rct2Index:
    """Cached listing of the RCT2 game data files."""

    def __init__(self, root):
        self.root = os.path.realpath(root) if root else None
        self.lock = threading.Lock()
        self.cached = None
        self.stamp = 0.0

    def manifest(self):
        if not self.root or not os.path.isdir(self.root):
            return None
        with self.lock:
            if self.cached is None or time.monotonic() - self.stamp > MANIFEST_TTL:
                self.cached = self._scan()
                self.stamp = time.monotonic()
            return self.cached

    def _scan(self):
        entries = []
        for top in RCT2_DIRS:
            base = os.path.join(self.root, top)
            for dirpath, _dirs, names in os.walk(base):
                for name in names:
                    full = os.path.join(dirpath, name)
                    try:
                        st = os.stat(full)
                    except OSError:
                        continue
                    if not os.path.isfile(full):
                        continue
                    rel = os.path.relpath(full, self.root).replace(os.sep, "/")
                    entries.append((rel, st.st_size, st.st_mtime_ns))
        entries.sort()
        digest = hashlib.sha1()
        for rel, size, mtime in entries:
            digest.update(f"{rel}\0{size}\0{mtime}\n".encode())
        return json.dumps(
            {"version": digest.hexdigest(), "files": [e[0] for e in entries]},
            separators=(",", ":"),
        ).encode()


def safe_join(root, rel):
    """Resolve rel under root; None when it escapes root or contains bad parts."""
    if "\0" in rel or "\\" in rel:
        return None
    parts = [p for p in rel.split("/") if p not in ("", ".")]
    if any(p == ".." for p in parts):
        return None
    full = os.path.realpath(os.path.join(root, *parts))
    if full != root and not full.startswith(root + os.sep):
        return None
    return full


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "openrct2-web"
    bridge = None
    rct2 = None
    www = None

    def log_message(self, fmt, *args):
        if self.path.startswith(("/bridge/next", "/api/health")):
            return
        sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))

    def _send(self, status, body=b"", ctype=None, extra=()):
        self.send_response(status)
        for k, v in SECURITY_HEADERS:
            self.send_header(k, v)
        if ctype:
            self.send_header("Content-Type", ctype)
        for k, v in extra:
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body and self.command != "HEAD":
            self.wfile.write(body)

    def _json(self, status, obj):
        self._send(status, json.dumps(obj, separators=(",", ":")).encode(), "application/json")

    def _file(self, path):
        if not os.path.isfile(path):
            return self._json(404, {"ok": False, "error": {"code": "not_found"}})
        ctype = MIME.get(os.path.splitext(path)[1].lower()) or mimetypes.guess_type(path)[0] or "application/octet-stream"
        size = os.path.getsize(path)
        self.send_response(200)
        for k, v in SECURITY_HEADERS:
            self.send_header(k, v)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(size))
        self.end_headers()
        if self.command == "HEAD":
            return
        with open(path, "rb") as fh:
            while True:
                chunk = fh.read(1 << 20)
                if not chunk:
                    break
                self.wfile.write(chunk)

    def _body(self, limit):
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            return None
        if length < 0 or length > limit:
            return None
        return self.rfile.read(length)

    def _peer_open(self):
        """False once the client has closed its end of the connection."""
        try:
            readable, _, _ = select.select([self.connection], [], [], 0)
            return not readable or self.connection.recv(1, socket.MSG_PEEK) != b""
        except (OSError, ValueError):
            return False

    def handle_one_request(self):
        try:
            super().handle_one_request()
        except (BrokenPipeError, ConnectionResetError):
            self.close_connection = True

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        path = unquote(urlsplit(self.path).path)
        if path == "/rct2/manifest.json":
            data = self.rct2.manifest()
            if data is None:
                return self._json(404, {"error": "no_rct2_data"})
            return self._send(200, data, "application/json")
        if path.startswith("/rct2/"):
            rel = path[len("/rct2/"):]
            if not self.rct2.root or rel.split("/", 1)[0] not in RCT2_DIRS:
                return self._json(404, {"ok": False, "error": {"code": "not_found"}})
            full = safe_join(self.rct2.root, rel)
            if full is None:
                return self._json(400, {"ok": False, "error": {"code": "bad_path"}})
            return self._file(full)
        if path == "/api/health":
            return self._json(200, {
                "ok": True,
                "connected": self.bridge.connected(),
                "version": API_VERSION,
            })
        if path == "/bridge/next":
            item = self.bridge.poll(POLL_TIMEOUT, self._peer_open)
            if item is None:
                return self._send(204)
            return self._json(200, item)
        if path == "/api" or path.startswith(("/api/", "/bridge/")):
            return self._json(404, {"ok": False, "error": {"code": "not_found"}})
        if path == "/":
            path = "/index.html"
        full = safe_join(self.www, path)
        if full is None:
            return self._json(400, {"ok": False, "error": {"code": "bad_path"}})
        return self._file(full)

    def do_POST(self):
        path = urlsplit(self.path).path
        if path == "/bridge/result":
            raw = self._body(MAX_RESULT_BODY)
            try:
                msg = json.loads(raw)
                rid, resp = msg["id"], msg["resp"]
            except (TypeError, ValueError, KeyError):
                return self._json(400, {"ok": False, "error": {"code": "bad_request"}})
            if not self.bridge.resolve(rid, resp):
                return self._json(404, {"ok": False, "error": {"code": "unknown_id"}})
            return self._json(200, {"ok": True})
        if path == "/api":
            raw = self._body(MAX_API_BODY)
            try:
                req = json.loads(raw)
            except (TypeError, ValueError):
                req = None
            if not isinstance(req, dict) or not isinstance(req.get("v"), str):
                return self._json(400, {"ok": False, "error": {
                    "code": "invalid_args", "message": "body must be a JSON object with string field \"v\""}})
            resp, err = self.bridge.submit(req, API_TIMEOUT)
            if err == "not_connected":
                return self._json(503, {"ok": False, "error": {
                    "code": "game_not_connected", "message": "no game page is polling /bridge/next"}})
            if err == "timeout":
                return self._json(504, {"ok": False, "error": {
                    "code": "timeout", "message": "game did not answer within 60s"}})
            return self._json(200, resp)
        return self._json(404, {"ok": False, "error": {"code": "not_found"}})


def default_rct2():
    try:
        with open(os.path.join(os.path.expanduser("~"), ".config/openrct2/game-path")) as fh:
            return fh.readline().strip() or None
    except OSError:
        return None


def default_www():
    here = os.path.dirname(os.path.realpath(__file__))
    for cand in (os.path.join(here, "..", "share", "openrct2-web", "www"), os.path.join(here, "web")):
        if os.path.isdir(cand):
            return os.path.realpath(cand)
    return os.path.join(here, "web")


def main():
    ap = argparse.ArgumentParser(description="OpenRCT2 web server and agent bridge")
    ap.add_argument("--port", type=int, default=8737)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--rct2", default=None, help="RCT2 data dir (default: first line of ~/.config/openrct2/game-path)")
    ap.add_argument("--www", default=None, help="directory served at / (default: package www)")
    args = ap.parse_args()

    Handler.bridge = Bridge()
    Handler.rct2 = Rct2Index(args.rct2 or default_rct2())
    Handler.www = os.path.realpath(args.www or default_www())

    ThreadingHTTPServer.daemon_threads = True
    ThreadingHTTPServer.request_queue_size = 64
    srv = ThreadingHTTPServer((args.host, args.port), Handler)
    sys.stderr.write(
        "openrct2-web on http://%s:%d  www=%s rct2=%s\n" % (args.host, args.port, Handler.www, Handler.rct2.root)
    )
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
