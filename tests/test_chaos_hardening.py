import gzip
import importlib.util
import json
import os
import re
import socket
import subprocess
import tempfile
import threading
import time
import unittest
from http.server import ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "scripts"
ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")


def find_free_port():
  with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
    s.bind(("127.0.0.1", 0))
    return s.getsockname()[1]


def load_receiver_module(cache_dir):
  os.environ["CC_WIDGET_CACHE_DIR"] = str(cache_dir)
  spec = importlib.util.spec_from_file_location(
    "session_account_receiver", SCRIPTS / "session-account-receiver.py"
  )
  mod = importlib.util.module_from_spec(spec)
  spec.loader.exec_module(mod)
  mod.CACHE_DIR = str(cache_dir)
  mod.MAP_PATH = os.path.join(str(cache_dir), "session-account.json")
  return mod


class ChaosHardeningTests(unittest.TestCase):
  def setUp(self):
    self.temp = tempfile.TemporaryDirectory()
    self.root = Path(self.temp.name)
    self.home = self.root / "home"
    self.cache = self.home / ".claude" / "cache"
    self.widget_cache = self.root / "widget-cache"
    self.workspace = self.root / "workspace"
    self.cache.mkdir(parents=True)
    self.widget_cache.mkdir()
    self.workspace.mkdir()
    self.theme = self.root / "theme.conf"
    self.theme.write_text('WT_STYLE="lean"\nWT_LAYOUT="fixed"\n')

  def tearDown(self):
    self.temp.cleanup()

  def base_env(self):
    env = os.environ.copy()
    for k in ("CLAUDE_CONFIG_DIR", "CC_SESSION_ID", "HC_TERMINAL_ID", "HC_TERMINAL_SOCKET"):
      env.pop(k, None)
    env.update({
      "HOME": str(self.home),
      "CC_WIDGET_CACHE_DIR": str(self.widget_cache),
      "CC_WIDGETS_CONF": str(self.theme),
      "WT_FORCE_COLS": "500",
      "WT_NO_LOG": "1",
    })
    return env

  def test_w07_wrapper_subagent_count_excludes_spawn_depth_2_and_above(self):
    tp = self.root / "session.jsonl"
    tp.write_text("")
    sub = self.root / "session" / "subagents"
    sub.mkdir(parents=True)
    (sub / "agent-a1.meta.json").write_text(json.dumps({"agentType": "explore", "spawnDepth": 1}))
    (sub / "agent-a2.meta.json").write_text(json.dumps({"agentType": "worker"}))
    (sub / "agent-a3.meta.json").write_text(json.dumps({"agentType": "nested", "spawnDepth": 2}))
    (sub / "agent-a4.meta.json").write_text(json.dumps({"agentType": "deep", "spawnDepth": 10}))

    payload = {
      "model": {"display_name": "Test"},
      "effort": {"level": "high"},
      "cost": {"total_cost_usd": 0},
      "workspace": {"current_dir": str(self.workspace)},
      "session_id": "subagent-depth-test",
      "transcript_path": str(tp),
      "context_window": {"used_percentage": 0, "context_window_size": 200000, "current_usage": {}},
    }
    res = subprocess.run(
      ["/bin/bash", str(SCRIPTS / "wrapper.sh")],
      input=json.dumps(payload),
      text=True,
      capture_output=True,
      env=self.base_env(),
      check=True,
    )
    plain = ANSI.sub("", res.stdout)
    self.assertIn("🤖 2", plain)
    self.assertNotIn("🤖 3", plain)
    self.assertNotIn("🤖 4", plain)

  def test_cs02_usage_color_non_numeric_symlink_clock_rollback_and_status_sanitize(self):
    # Non-numeric utilization and weekly_scoped -> zero stderr and renders ?
    (self.cache / "quota-bad_at_example.com.json").write_text(json.dumps({
      "data": {
        "five_hour": {"utilization": "not-a-num", "resets_at": None},
        "seven_day": {"utilization": True, "resets_at": None},
        "limits": [{"kind": "weekly_scoped", "percent": "bad"}],
      }
    }))
    # Symlinked cache with old mtime -> stat -L follows symlink and shows stale
    real_target = self.root / "real-quota.json"
    real_target.write_text(json.dumps({
      "data": {
        "five_hour": {"utilization": 10, "resets_at": None},
        "seven_day": {"utilization": 20, "resets_at": None},
      }
    }))
    old_mtime = time.time() - 700
    os.utime(real_target, (old_mtime, old_mtime))
    os.symlink(real_target, self.cache / "quota-sym_at_example.com.json")

    # Future mtime -> age clamped to 0, no negative age tag
    future_file = self.cache / "quota-future_at_example.com.json"
    future_file.write_text(json.dumps({
      "data": {
        "five_hour": {"utilization": 5, "resets_at": None},
        "seven_day": {"utilization": 15, "resets_at": None},
      }
    }))
    future_mtime = time.time() + 3600
    os.utime(future_file, (future_mtime, future_mtime))

    # Control chars in .status
    (self.cache / "quota-ctrl_at_example.com.status").write_text("12:00\x01\r\tbad\x07msg\n")

    env = os.environ.copy()
    for k in ("CLAUDE_CONFIG_DIR", "CC_SESSION_ID", "CC_WIDGET_CACHE_DIR"):
      env.pop(k, None)
    env["HOME"] = str(self.home)
    res = subprocess.run(
      ["/bin/bash", str(SCRIPTS / "usage-color.sh")],
      capture_output=True,
      text=True,
      env=env,
    )
    self.assertEqual(res.returncode, 0)
    self.assertEqual(res.stderr, "")
    plain = ANSI.sub("", res.stdout)
    self.assertIn("bad: ? — | ? —", plain)
    self.assertIn("sym: [⚠ ", plain)
    self.assertIn("stale]", plain)
    self.assertNotIn("[-", plain)
    self.assertIn("ctrl | ⚠ badmsg @ 12:00", plain)
    self.assertNotIn("\x01", plain)
    self.assertNotIn("\x07", plain)

  def test_cs03_wrapper_stdin_newline_path_traversal_clock_rollback_and_balance_sanitize(self):
    # 1) stdin JSON with newlines/control chars & bad numeric fields -> zero stderr
    payload = {
      "model": {"display_name": "Line1\nLine2\x07", "id": "id\r\x01"},
      "effort": {"level": "high\n"},
      "cost": {"total_cost_usd": "bad"},
      "workspace": {"current_dir": str(self.workspace)},
      "session_id": "../escape",
      "context_window": {
        "used_percentage": "nan",
        "context_window_size": "bad",
        "current_usage": {"input_tokens": "bad"},
      },
    }
    env = self.base_env()
    env.pop("WT_NO_LOG", None)

    # Pre-seed corrupt .widget-log-last-ts and dirty devin balance_usd
    (self.widget_cache / ".widget-log-last-ts").write_text("corrupt-ts")
    (self.cache / "vendor-devin-pool.json").write_text(json.dumps({
      "fetched_at": int(time.time()),
      "data": {
        "used_1d_pct": 10,
        "reset_1d_at": int(time.time()) + 3600,
        "used_7d_pct": 20,
        "reset_7d_at": int(time.time()) + 86400,
        "avail_seats": 2,
        "total_seats": 3,
        "error_seats": 0,
        "balance_usd": "123.45\n\x07",
      },
    }))

    res = subprocess.run(
      ["/bin/bash", str(SCRIPTS / "wrapper.sh")],
      input=json.dumps(payload),
      text=True,
      capture_output=True,
      env=env,
    )
    self.assertEqual(res.returncode, 0)
    self.assertEqual(res.stderr, "")
    # Path traversal blocked: no escape.* files in parent of widget_cache
    self.assertEqual(list(self.root.glob("*escape*")), [])
    # .widget-log-last-ts recovered to numeric epoch and log written
    last_ts = (self.widget_cache / ".widget-log-last-ts").read_text()
    self.assertRegex(last_ts, r"^\d+$")
    log_files = list((self.home / ".claude" / "projects" / "widget-log").glob("*.jsonl"))
    self.assertEqual(len(log_files), 1)
    log_entry = json.loads(log_files[0].read_text().splitlines()[-1])
    self.assertEqual(log_entry["devin_balance_usd"], "123.45")

    # 2) Clock rollback: future-dated .widget-log-last-ts allows writing again
    (self.widget_cache / ".widget-log-last-ts").write_text(str(int(time.time()) + 3600))
    res2 = subprocess.run(
      ["/bin/bash", str(SCRIPTS / "wrapper.sh")],
      input=json.dumps(payload),
      text=True,
      capture_output=True,
      env=env,
    )
    self.assertEqual(res2.returncode, 0)
    self.assertEqual(len(log_files[0].read_text().splitlines()), 2)

    # 3) Clock rollback: future-dated vendor-pills.memo is NOT reused
    vendor_memo = self.widget_cache / "vendor-pills.memo"
    self.assertTrue(vendor_memo.exists())
    lines = vendor_memo.read_text().splitlines()
    future_ts = int(time.time()) + 3600
    # Replace memo timestamp with future ts and poison cached DEVIN_PILL_OUT
    parts = lines[1].split("\x1f")
    parts[16] = "Devin: STALE_MEMO_POISON"
    vendor_memo.write_text(f"{future_ts} {lines[0].split(' ', 1)[1]}\n" + "\x1f".join(parts) + "\n")
    res3 = subprocess.run(
      ["/bin/bash", str(SCRIPTS / "wrapper.sh")],
      input=json.dumps(payload),
      text=True,
      capture_output=True,
      env=self.base_env(),
    )
    self.assertEqual(res3.returncode, 0)
    self.assertNotIn("STALE_MEMO_POISON", res3.stdout)
    self.assertIn("Devin: 10%", ANSI.sub("", res3.stdout))

  def test_cs04_skill_hook_fast_path_traversal_control_chars_and_atomic_write(self):
    env = self.base_env()
    hook = str(SCRIPTS / "skill-hook.sh")

    # Fast-path skips irrelevant event
    r0 = subprocess.run(
      ["/bin/bash", hook],
      input=json.dumps({"hook_event_name": "PostToolUse", "session_id": "s1", "tool_name": "Skill"}),
      text=True, capture_output=True, env=env, check=True,
    )
    self.assertEqual(r0.stdout.strip(), "{}")
    self.assertFalse((self.widget_cache / "skill-s1.txt").exists())

    # Path traversal rejected
    subprocess.run(
      ["/bin/bash", hook],
      input=json.dumps({
        "hook_event_name": "PreToolUse", "tool_name": "Skill",
        "session_id": "../evil", "tool_input": {"skill": "tdd"},
      }),
      text=True, capture_output=True, env=env, check=True,
    )
    self.assertEqual(list(self.root.glob("*evil*")), [])
    self.assertEqual(list(self.widget_cache.glob("skill-*")), [])

    # Control-char-only skill skipped
    subprocess.run(
      ["/bin/bash", hook],
      input=json.dumps({
        "hook_event_name": "PreToolUse", "tool_name": "Skill",
        "session_id": "s-ctrl", "tool_input": {"skill": "\n\r\t\x07"},
      }),
      text=True, capture_output=True, env=env, check=True,
    )
    self.assertFalse((self.widget_cache / "skill-s-ctrl.txt").exists())

    # Control chars stripped from skill name and written atomically
    subprocess.run(
      ["/bin/bash", hook],
      input=json.dumps({
        "hook_event_name": "PreToolUse", "tool_name": "Skill",
        "session_id": "s-ok", "tool_input": {"skill": "my\n\x07skill"},
      }),
      text=True, capture_output=True, env=env, check=True,
    )
    self.assertEqual((self.widget_cache / "skill-s-ok.txt").read_text(), "myskill")
    self.assertEqual(list(self.widget_cache.glob(".skill-*")), [])

    # UserPromptSubmit preserves newline boundary before body
    subprocess.run(
      ["/bin/bash", hook],
      input=json.dumps({
        "hook_event_name": "UserPromptSubmit",
        "session_id": "s-prompt",
        "prompt": "/implement\nplease start",
      }),
      text=True, capture_output=True, env=env, check=True,
    )
    self.assertEqual((self.widget_cache / "skill-s-prompt.txt").read_text(), "implement")

  def test_cs05_subagent_panel_succeeds_with_home_unset(self):
    env = {"PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin"}
    tp = self.root / "panel.jsonl"
    tp.write_text("")
    payload = {
      "session_id": "s",
      "transcript_path": str(tp),
      "columns": 120,
      "tasks": [{
        "id": "a1",
        "type": "local_agent",
        "status": "running",
        "description": "Test",
        "model": "claude-sonnet-5-5",
        "contextWindowSize": 200000,
        "tokenCount": 10000,
      }],
    }
    res = subprocess.run(
      ["/bin/bash", str(SCRIPTS / "subagent-panel.sh")],
      input=json.dumps(payload),
      text=True,
      capture_output=True,
      env=env,
      timeout=20,
    )
    self.assertEqual(res.returncode, 0, res.stderr)
    self.assertEqual(res.stderr, "")
    row = json.loads(res.stdout.splitlines()[0])
    self.assertEqual(row["id"], "a1")

  def test_cs06_daemon_corrupt_last_singleton_lock_and_sigterm_kills_grandchildren(self):
    port = find_free_port()
    widget_script = self.root / "w.sh"
    widget_script.write_text("#!/usr/bin/env bash\nprintf 'ok'\n")
    widget_script.chmod(0o755)

    # Seed corrupt .last-w1, future .last-w2 (clock rollback), and stale lock
    (self.widget_cache / ".last-w1").write_text("not-a-number")
    (self.widget_cache / ".last-w2").write_text(str(int(time.time()) + 3600))
    stale_lock = self.widget_cache / ".daemon.lock"
    stale_lock.mkdir()
    (stale_lock / "pid").write_text("corrupt-pid")

    env = self.base_env()
    env.update({
      "CC_SESSION_ACCOUNT_PORT": str(port),
      "DAEMON_WIDGETS_OVERRIDE": f"w1|{widget_script}|1\nw2|{widget_script}|60",
    })

    proc = subprocess.Popen(
      ["/bin/bash", str(SCRIPTS / "daemon.sh")],
      env=env,
      stdout=subprocess.DEVNULL,
      stderr=subprocess.PIPE,
      text=True,
    )
    try:
      deadline = time.time() + 10
      receiver_up = False
      while time.time() < deadline:
        if (self.widget_cache / "w1.txt").exists() and (self.widget_cache / "w2.txt").exists():
          try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2):
              receiver_up = True
              break
          except OSError:
            pass
        time.sleep(0.1)
      self.assertTrue(receiver_up, "daemon failed to start widgets and receiver")
      self.assertEqual((self.widget_cache / "w1.txt").read_text(), "ok")
      self.assertEqual((self.widget_cache / "w2.txt").read_text(), "ok")
      self.assertEqual((stale_lock / "pid").read_text().strip(), str(proc.pid))

      # Second daemon sees live lock and exits 0 immediately
      dup = subprocess.run(
        ["/bin/bash", str(SCRIPTS / "daemon.sh")],
        env=env, capture_output=True, text=True, timeout=5,
      )
      self.assertEqual(dup.returncode, 0)
      self.assertEqual((stale_lock / "pid").read_text().strip(), str(proc.pid))
    finally:
      proc.terminate()
      try:
        _, stderr = proc.communicate(timeout=5)
      except subprocess.TimeoutExpired:
        proc.kill()
        _, stderr = proc.communicate(timeout=5)

    self.assertEqual(proc.returncode, 0, stderr)
    self.assertFalse(stale_lock.exists(), "daemon lock should be cleaned on SIGTERM")
    self.assertNotIn("syntax error", stderr.lower())
    self.assertNotIn("unbound variable", stderr.lower())
    # Verify grandchild receiver process was terminated (port closed)
    with self.assertRaises(OSError):
      with socket.create_connection(("127.0.0.1", port), timeout=0.5):
        pass

  def test_cs07_receiver_hardening_and_http_guards(self):
    mod = load_receiver_module(self.widget_cache)

    # Non-dict JSON recovery
    Path(mod.MAP_PATH).write_text("[]")
    self.assertEqual(mod.load_map(), {})

    # Corrupt ts entries cleaned without crashing
    now = int(time.time())
    Path(mod.MAP_PATH).write_text(json.dumps({
      "sessions": {
        "bad-none": {"email": "a@b.com", "ts": None},
        "bad-bool": {"email": "a@b.com", "ts": True},
        "bad-str": {"email": "a@b.com", "ts": "123"},
        "expired": {"email": "old@b.com", "ts": now - mod.TTL_SECONDS - 10},
        "keep": {"email": "keep@b.com", "ts": now - 10},
      }
    }))
    mod.record({"new-sid": "new@b.com"})
    loaded = mod.load_map()
    self.assertEqual(set(loaded.keys()), {"keep", "new-sid"})
    self.assertEqual(os.stat(mod.MAP_PATH).st_mode & 0o777, 0o600)

    # Deeply nested JSON (> 2000 levels) handled iteratively without RecursionError
    deep = {
      "attributes": [
        {"key": "session.id", "value": {"stringValue": "deep-sid"}},
        {"key": "user.email", "value": {"stringValue": "deep@example.com"}},
      ]
    }
    for _ in range(2500):
      deep = {"nested": [deep]}
    found = mod.collect_pairs(deep, {})
    self.assertEqual(found, {"deep-sid": "deep@example.com"})

    # Live HTTP checks for bad Content-Length and gzip bomb
    server = ThreadingHTTPServer(("127.0.0.1", 0), mod.Handler)
    server.daemon_threads = True
    port = server.server_address[1]
    t = threading.Thread(target=server.serve_forever, daemon=True)
    t.start()
    self.addCleanup(lambda: (server.shutdown(), server.server_close()))

    def raw_post(headers, body=b""):
      with socket.create_connection(("127.0.0.1", port), timeout=5) as sock:
        req = f"POST /v1/metrics HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n{headers}\r\n".encode() + body
        sock.sendall(req)
        resp = sock.recv(4096).decode("latin1")
        return int(resp.splitlines()[0].split()[1])

    self.assertEqual(raw_post("Content-Length: not-an-int\r\n"), 400)

    bomb = gzip.compress(b"0" * (mod.MAX_BODY + 1024))
    self.assertLess(len(bomb), mod.MAX_BODY)
    self.assertEqual(
      raw_post(f"Content-Length: {len(bomb)}\r\nContent-Encoding: gzip\r\n", bomb),
      413,
    )

    good = json.dumps({
      "resourceMetrics": [{
        "scopeMetrics": [{
          "metrics": [{
            "sum": {
              "dataPoints": [{
                "attributes": [
                  {"key": "session.id", "value": {"stringValue": "http-sid"}},
                  {"key": "user.email", "value": {"stringValue": "http@example.com"}},
                ]
              }]
            }
          }]
        }]
      }]
    }).encode()
    self.assertEqual(raw_post(f"Content-Length: {len(good)}\r\n", good), 200)
    self.assertEqual(mod.load_map()["http-sid"]["email"], "http@example.com")


if __name__ == "__main__":
  unittest.main()
