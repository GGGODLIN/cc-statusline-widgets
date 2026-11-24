import json
import os
import socket
import stat
import subprocess
import time
import unittest

# Import the module, not the class, so unittest doesn't collect the quota tests here too.
import test_wrapper_quota as quota

FAKE_RECORDER = """#!/bin/bash
printf '%s\\0' "$@" > "$FAKE_RECORD_LOG"
exit "${FAKE_RECORD_EXIT:-0}"
"""


class WrapperHerdrRestoreHookTests(unittest.TestCase):
  setUp = quota.WrapperQuotaContractTests.setUp
  tearDown = quota.WrapperQuotaContractTests.tearDown

  def start_herdr_app(self):
    if hasattr(self, "herdr_app"):
      return self.herdr_app
    herdr_home = self.home / ".config/herdr-app"
    herdr_home.mkdir(parents=True, exist_ok=True)
    sock_path = herdr_home / "herdr-app.sock"
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(str(sock_path))
    self.addCleanup(srv.close)
    self.herdr_app = (herdr_home, sock_path)
    return self.herdr_app

  def fake_recorder(self, name="fake-herdr-restore"):
    path = self.root / name
    path.write_text(FAKE_RECORDER)
    path.chmod(path.stat().st_mode | stat.S_IXUSR)
    return path

  def run_wrapper(self, *, in_herdr, recorder, extra_env=None, keep_stamp=False):
    """Run the wrapper once. Returns (completed process, cc-status JSON or None, recorded argv or None).

    The once-a-minute stamp is cleared first unless keep_stamp: otherwise a "not called" assertion after
    a positive-control run would pass because of the throttle instead of the guard it is meant to test."""
    herdr_home, sock_path = self.start_herdr_app()
    record_log = self.root / "record-argv"
    record_log.unlink(missing_ok=True)
    if not keep_stamp:
      for stamp in self.widget_cache.glob("herdr-restore-*.stamp"):
        stamp.unlink()
    env = {
      **os.environ,
      "HOME": str(self.home),
      "HERDR_APP_HOME": str(herdr_home),
      "HERDR_APP_SOCK": str(sock_path),
      "CC_WIDGETS_CONF": str(self.theme),
      "WT_FORCE_COLS": "500",
      "HERDR_RESTORE_BIN": str(recorder),
      "FAKE_RECORD_LOG": str(record_log),
    }
    for name in ("HC_TERMINAL_ID", "WT_NO_LOG", "WT_FORCE_STDOUT"):
      env.pop(name, None)
    if in_herdr:
      env["HC_TERMINAL_ID"] = "t42"
    env.update(extra_env or {})
    result = subprocess.run(["/bin/bash", str(self.wrapper)], input=json.dumps(self.input),
                            text=True, capture_output=True, env=env, check=True)
    status_file = herdr_home / "data/cc-status/t42.json"
    status = json.loads(status_file.read_text()) if status_file.is_file() else None
    status_file.unlink(missing_ok=True)
    return result, status, record_log

  def wait_for_call(self, record_log, timeout=5.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
      if record_log.is_file() and record_log.stat().st_size > 0:
        return record_log.read_bytes().decode().split("\0")[:-1]
      time.sleep(0.05)
    return None

  def assert_no_call(self, record_log):
    time.sleep(1.0)
    self.assertFalse(record_log.exists(), "the record command must not have been called")

  def comparable(self, status):
    # timestamps move between runs; everything else must stay put
    return {key: value for key, value in status.items() if not key.endswith("_at")}

  def test_herdr_terminal_calls_record_with_what_the_statusline_knows(self):
    transcript = self.root / "session.jsonl"
    transcript.write_text("")
    self.input["transcript_path"] = str(transcript)

    _, _, record_log = self.run_wrapper(in_herdr=True, recorder=self.fake_recorder())

    self.assertEqual(self.wait_for_call(record_log), [
      "record",
      "--terminal=t42",
      "--session=quota-contract",
      f"--cwd={self.workspace}",
      "--effort=high",
      f"--transcript={transcript}",
      f"--from-pid={os.getpid()}",
    ])

  def test_statusline_output_and_cc_status_file_are_the_same_with_and_without_the_hook(self):
    hooked, hooked_status, record_log = self.run_wrapper(in_herdr=True, recorder=self.fake_recorder())
    self.assertIsNotNone(self.wait_for_call(record_log), "positive control: the hook ran in this scenario")
    bare, bare_status, _ = self.run_wrapper(in_herdr=True, recorder=self.root / "does-not-exist")

    self.assertEqual(hooked.stdout, bare.stdout)
    self.assertEqual(hooked.stderr, bare.stderr)
    self.assertIsNotNone(hooked_status)
    self.assertIn("lines", hooked_status)
    self.assertEqual(self.comparable(hooked_status), self.comparable(bare_status))

  def test_outside_a_herdr_terminal_nothing_is_recorded_and_stdout_is_unchanged(self):
    _, _, control_log = self.run_wrapper(in_herdr=True, recorder=self.fake_recorder())
    self.assertIsNotNone(self.wait_for_call(control_log), "positive control: the same setup in Herdr calls it")

    hooked, _, record_log = self.run_wrapper(in_herdr=False, recorder=self.fake_recorder())
    bare, _, _ = self.run_wrapper(in_herdr=False, recorder=self.root / "does-not-exist")

    self.assert_no_call(record_log)
    self.assertIn("◆", hooked.stdout)
    self.assertEqual(hooked.stdout, bare.stdout)

  def test_preview_mode_never_records(self):
    _, _, control_log = self.run_wrapper(in_herdr=True, recorder=self.fake_recorder())
    self.assertIsNotNone(self.wait_for_call(control_log), "positive control: without preview mode it is called")

    _, _, record_log = self.run_wrapper(in_herdr=True, recorder=self.fake_recorder(), extra_env={"WT_NO_LOG": "1"})

    self.assert_no_call(record_log)

  def test_a_session_without_an_id_is_not_recorded(self):
    _, _, control_log = self.run_wrapper(in_herdr=True, recorder=self.fake_recorder())
    self.assertIsNotNone(self.wait_for_call(control_log), "positive control: with a session id it is called")
    self.input["session_id"] = ""

    _, _, record_log = self.run_wrapper(in_herdr=True, recorder=self.fake_recorder())

    self.assert_no_call(record_log)

  def test_a_failing_record_command_does_not_change_the_statusline(self):
    failing, failing_status, record_log = self.run_wrapper(
      in_herdr=True, recorder=self.fake_recorder(), extra_env={"FAKE_RECORD_EXIT": "1"})
    self.assertIsNotNone(self.wait_for_call(record_log), "positive control: the failing command did run")
    bare, bare_status, _ = self.run_wrapper(in_herdr=True, recorder=self.root / "does-not-exist")

    self.assertEqual((failing.returncode, failing.stdout, failing.stderr), (0, bare.stdout, bare.stderr))
    self.assertEqual(self.comparable(failing_status), self.comparable(bare_status))

  def test_default_binary_name_is_looked_up_on_path(self):
    bin_dir = self.root / "bin"
    bin_dir.mkdir()
    fake = self.fake_recorder()
    (bin_dir / "herdr-restore").write_bytes(fake.read_bytes())
    (bin_dir / "herdr-restore").chmod(0o755)

    _, _, record_log = self.run_wrapper(in_herdr=True, recorder=self.root / "unused", extra_env={
      "HERDR_RESTORE_BIN": "", "PATH": f"{bin_dir}:{os.environ['PATH']}"})

    self.assertIsNotNone(self.wait_for_call(record_log))

  def test_a_repeat_within_a_minute_for_the_same_session_and_effort_is_not_recorded(self):
    _, _, first_log = self.run_wrapper(in_herdr=True, recorder=self.fake_recorder())
    self.assertIsNotNone(self.wait_for_call(first_log), "positive control: the first refresh records")

    _, _, record_log = self.run_wrapper(in_herdr=True, recorder=self.fake_recorder(), keep_stamp=True)

    self.assert_no_call(record_log)

  def test_a_new_session_or_a_new_effort_is_recorded_at_once(self):
    _, _, first_log = self.run_wrapper(in_herdr=True, recorder=self.fake_recorder())
    self.assertIsNotNone(self.wait_for_call(first_log))

    self.input["session_id"] = "another-session"
    _, _, session_log = self.run_wrapper(in_herdr=True, recorder=self.fake_recorder(), keep_stamp=True)
    self.assertIn("--session=another-session", self.wait_for_call(session_log) or [])

    self.input["effort"] = {"level": "low"}
    _, _, effort_log = self.run_wrapper(in_herdr=True, recorder=self.fake_recorder(), keep_stamp=True)
    self.assertIn("--effort=low", self.wait_for_call(effort_log) or [])

  def test_a_minute_after_the_last_record_it_is_recorded_again(self):
    _, _, first_log = self.run_wrapper(in_herdr=True, recorder=self.fake_recorder())
    self.assertIsNotNone(self.wait_for_call(first_log))
    stamp = self.widget_cache / "herdr-restore-t42.stamp"
    _, sid, effort = stamp.read_text().split(" ", 2)
    stamp.write_text(f"{int(time.time()) - 61} {sid} {effort}")

    _, _, record_log = self.run_wrapper(in_herdr=True, recorder=self.fake_recorder(), keep_stamp=True)

    self.assertIsNotNone(self.wait_for_call(record_log))


if __name__ == "__main__":
  unittest.main()
