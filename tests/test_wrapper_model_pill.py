import json
import os
import socket
import subprocess
import unittest

# Import the module, not the class, so unittest doesn't collect the quota tests here too.
import test_wrapper_quota as quota

DARK_INK = "\x1b[38;2;42;49;66m"


class WrapperModelPillTests(unittest.TestCase):
  setUp = quota.WrapperQuotaContractTests.setUp
  tearDown = quota.WrapperQuotaContractTests.tearDown

  def first_line_raw(self, theme):
    self.theme.write_text(theme)
    env = {**os.environ, "HOME": str(self.home), "CC_WIDGETS_CONF": str(self.theme),
           "WT_FORCE_COLS": "500", "WT_NO_LOG": "1"}
    result = subprocess.run(["/bin/bash", str(self.wrapper)], input=json.dumps(self.input),
                            text=True, capture_output=True, env=env, check=True)
    return result.stdout.splitlines()[0]

  def test_model_text_color_can_be_set_for_that_pill_alone(self):
    line = self.first_line_raw('WT_STYLE="pill"\nWT_BG_MODEL="196,183,220"\nWT_FG_MODEL="42,49,66"\n')

    model_at = line.index("◆")
    self.assertEqual(line[:model_at].rfind(DARK_INK) + len(DARK_INK), line[:model_at].rfind("\x1b[1m"),
                     "dark ink should be the last color before the bold model text")
    self.assertEqual(line.count(DARK_INK), 1, "only the model pill takes the custom ink")

  def test_without_the_option_the_pill_keeps_the_theme_text_color(self):
    line = self.first_line_raw('WT_STYLE="pill"\nWT_BG_MODEL="196,183,220"\n')

    self.assertNotIn(DARK_INK, line)

  def test_herdr_app_terminal_suppresses_stdout_and_writes_mod_json(self):
    herdr_home = self.home / ".config/herdr-app"
    herdr_home.mkdir(parents=True)
    sock_path = herdr_home / "herdr-app.sock"
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(str(sock_path))
    self.addCleanup(srv.close)
    env = {
      **os.environ,
      "HOME": str(self.home),
      "HERDR_APP_HOME": str(herdr_home),
      "HERDR_APP_SOCK": str(sock_path),
      "HC_TERMINAL_ID": "t42",
      "CC_WIDGETS_CONF": str(self.theme),
    }
    env.pop("WT_NO_LOG", None)
    env.pop("WT_FORCE_STDOUT", None)
    result = subprocess.run(["/bin/bash", str(self.wrapper)], input=json.dumps(self.input),
                            text=True, capture_output=True, env=env, check=True)
    self.assertEqual(result.stdout, "")
    term_json = herdr_home / "data/cc-status/t42.json"
    global_json = herdr_home / "data/cc-status/_global.json"
    self.assertTrue(term_json.is_file())
    self.assertTrue(global_json.is_file())
    payload = json.loads(term_json.read_text())
    self.assertEqual(payload["terminal"], "t42")
    self.assertEqual(len(payload["lines"]), 3)
    self.assertIn("◆", payload["lines"][0][0]["spans"][0]["text"])

  def test_outside_herdr_app_still_prints_stdout_statusline(self):
    herdr_home = self.home / ".config/herdr-app"
    herdr_home.mkdir(parents=True)
    env = {
      **os.environ,
      "HOME": str(self.home),
      "HERDR_APP_HOME": str(herdr_home),
      "CC_WIDGETS_CONF": str(self.theme),
      "WT_FORCE_COLS": "500",
    }
    env.pop("HC_TERMINAL_ID", None)
    env.pop("WT_NO_LOG", None)
    result = subprocess.run(["/bin/bash", str(self.wrapper)], input=json.dumps(self.input),
                            text=True, capture_output=True, env=env, check=True)
    self.assertGreaterEqual(len(result.stdout.splitlines()), 2)
    self.assertIn("◆", result.stdout)


if __name__ == "__main__":
  unittest.main()
