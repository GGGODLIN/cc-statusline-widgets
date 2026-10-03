import json
import os
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


if __name__ == "__main__":
  unittest.main()
