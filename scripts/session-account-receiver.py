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

import gzip
import json
import os
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CACHE_DIR = os.environ.get("CC_WIDGET_CACHE_DIR", "/tmp/cc-widget-cache")
MAP_PATH = os.path.join(CACHE_DIR, "session-account.json")
HOST = "127.0.0.1"
PORT = int(os.environ.get("CC_SESSION_ACCOUNT_PORT", "4318"))
TTL_SECONDS = 86400
MAX_BODY = 8 * 1024 * 1024

_lock = threading.Lock()


def collect_pairs(node, found):
    if isinstance(node, dict):
        attrs = node.get("attributes")
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
        for value in node.values():
            collect_pairs(value, found)
    elif isinstance(node, list):
        for value in node:
            collect_pairs(value, found)
    return found


def load_map():
    try:
        with open(MAP_PATH, "r") as handle:
            data = json.load(handle)
    except (OSError, ValueError):
        return {}
    sessions = data.get("sessions")
    return sessions if isinstance(sessions, dict) else {}


def save_map(sessions):
    os.makedirs(CACHE_DIR, exist_ok=True)
    tmp_path = MAP_PATH + ".tmp"
    with open(tmp_path, "w") as handle:
        json.dump({"sessions": sessions}, handle)
    os.replace(tmp_path, MAP_PATH)


def record(pairs):
    if not pairs:
        return
    now = int(time.time())
    with _lock:
        sessions = load_map()
        for sid, email in pairs.items():
            sessions[sid] = {"email": email, "ts": now}
        sessions = {
            sid: entry
            for sid, entry in sessions.items()
            if isinstance(entry, dict) and now - int(entry.get("ts", 0)) <= TTL_SECONDS
        }
        save_map(sessions)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0 or length > MAX_BODY:
            self.reply(400, b'{"error":"bad length"}')
            return
        body = self.rfile.read(length)
        if (self.headers.get("Content-Encoding") or "").lower() == "gzip":
            try:
                body = gzip.decompress(body)
            except OSError:
                self.reply(400, b'{"error":"bad gzip"}')
                return
        try:
            payload = json.loads(body)
        except ValueError:
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
