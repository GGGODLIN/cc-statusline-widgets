#!/usr/bin/env python3
# session-account-receiver.py — OTLP/HTTP receiver that maps CC session.id -> user.email.
#
# 為什麼需要它：CC 的憑證是 per-process 的（一個 session 跑 /login 不會換掉其他
# 正在跑的 session），但 statusline 拿到的 stdin 沒有帳號欄，$HOME/.claude.json
# 只記「最後一次登入誰」。CC 的 OTel metric 每筆都同時帶 session.id 與 user.email，
# 且該值來自程序自己的憑證（2026-09-10 實測：CLAUDE_CONFIG_DIR=~/.claude-team-s
# 的程序送出 software.agent，同時全域檔記的是 philiplin）——這是唯一與程序直接
# 綁定的帳號來源。
#
# 輸出 /tmp/cc-widget-cache/session-account.json，usage-color.sh 用 CC_SESSION_ID 查。

import fcntl
import json
import os
import tempfile
import threading
import time
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CACHE_DIR = os.environ.get("CC_WIDGET_CACHE_DIR", "/tmp/cc-widget-cache")
MAP_PATH = os.path.join(CACHE_DIR, "session-account.json")
HOST = "127.0.0.1"
PORT = int(os.environ.get("CC_SESSION_ACCOUNT_PORT", "4318"))
TTL_SECONDS = 86400
MAX_BODY = 8 * 1024 * 1024

_lock = threading.Lock()


def collect_pairs(node, found):
    stack = [node]
    while stack:
        cur = stack.pop()
        if isinstance(cur, dict):
            attrs = cur.get("attributes")
            if isinstance(attrs, list):
                flat = {}
                for item in attrs:
                    if not isinstance(item, dict):
                        continue
                    key = item.get("key")
                    value = item.get("value")
                    if isinstance(key, str) and isinstance(value, dict):
                        text = value.get("stringValue")
                        if isinstance(text, str):
                            flat[key] = text
                sid = flat.get("session.id")
                email = flat.get("user.email")
                if sid and email:
                    found[sid] = email
            stack.extend(cur.values())
        elif isinstance(cur, list):
            stack.extend(cur)
    return found


def load_map():
    try:
        with open(MAP_PATH, "r") as handle:
            data = json.load(handle)
    except (OSError, ValueError):
        return {}
    if not isinstance(data, dict):
        return {}
    sessions = data.get("sessions")
    return sessions if isinstance(sessions, dict) else {}


def save_map(sessions):
    os.makedirs(CACHE_DIR, exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(dir=CACHE_DIR, prefix=".session-account.tmp-")
    try:
        with os.fdopen(fd, "w") as handle:
            json.dump({"sessions": sessions}, handle)
        os.chmod(tmp_path, 0o600)
        os.replace(tmp_path, MAP_PATH)
    except Exception:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


def record(pairs):
    if not pairs:
        return
    now = int(time.time())
    os.makedirs(CACHE_DIR, exist_ok=True)
    lock_path = os.path.join(CACHE_DIR, "session-account.lock")
    with _lock:
        with open(lock_path, "a+") as lock_file:
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
            try:
                sessions = load_map()
                for sid, email in pairs.items():
                    sessions[sid] = {"email": email, "ts": now}
                cleaned = {}
                for sid, entry in sessions.items():
                    if not isinstance(entry, dict):
                        continue
                    ts = entry.get("ts")
                    if not isinstance(ts, int) or isinstance(ts, bool):
                        continue
                    if now - ts <= TTL_SECONDS:
                        cleaned[sid] = entry
                save_map(cleaned)
            finally:
                fcntl.flock(lock_file.fileno(), fcntl.LOCK_UN)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    timeout = 5

    def do_POST(self):
        raw_length = self.headers.get("Content-Length")
        try:
            length = int(raw_length if raw_length is not None else 0)
        except ValueError:
            self.reply(400, b'{"error":"bad length"}')
            return
        if length <= 0 or length > MAX_BODY:
            self.reply(400, b'{"error":"bad length"}')
            return
        try:
            body = self.rfile.read(length)
        except OSError:
            self.reply(400, b'{"error":"bad length"}')
            return
        if (self.headers.get("Content-Encoding") or "").lower() == "gzip":
            try:
                decomp = zlib.decompressobj(16 + zlib.MAX_WBITS)
                out = decomp.decompress(body, MAX_BODY + 1)
                if len(out) > MAX_BODY or decomp.unconsumed_tail:
                    self.reply(413, b'{"error":"too large"}')
                    return
                out += decomp.flush()
                if len(out) > MAX_BODY:
                    self.reply(413, b'{"error":"too large"}')
                    return
                if not decomp.eof:
                    self.reply(400, b'{"error":"bad gzip"}')
                    return
                body = out
            except (OSError, EOFError, zlib.error):
                self.reply(400, b'{"error":"bad gzip"}')
                return
        try:
            payload = json.loads(body)
        except (ValueError, RecursionError):
            self.reply(415, b'{"error":"json only"}')
            return
        try:
            record(collect_pairs(payload, {}))
        except Exception:
            pass
        self.reply(200, b"{}")

    def do_GET(self):
        self.reply(200, b"{}")

    def reply(self, code, body):
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except OSError:
            pass

    def log_message(self, *args):
        pass


def main():
    os.makedirs(CACHE_DIR, exist_ok=True)
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    server.daemon_threads = True
    server.serve_forever()


if __name__ == "__main__":
    main()
