from pathlib import Path
import unittest


REPO = Path(__file__).parents[1]
RUNTIME = Path.home() / ".claude/scripts/cc-statusline"


class RuntimeParityTest(unittest.TestCase):
  def test_installed_scripts_match_source(self):
    pairs = {
      REPO / "scripts/wrapper.sh": RUNTIME / "wrapper.sh",
      REPO / "scripts/daemon.sh": RUNTIME / "daemon.sh",
      REPO / "scripts/free-memory.sh": RUNTIME / "free-memory.sh",
      REPO / "scripts/cpu-usage.sh": RUNTIME / "cpu-usage.sh",
      REPO / "scripts/thermals.sh": RUNTIME / "thermals.sh",
      REPO / "scripts/skill-hook.sh": RUNTIME / "skill-hook.sh",
      REPO / "scripts/runaway.sh": RUNTIME / "runaway.sh",
      REPO / "scripts/usage-color.sh": Path.home() / ".claude/scripts/usage-color.sh",
    }
    for source, runtime in pairs.items():
      with self.subTest(source=source.name):
        self.assertEqual(runtime.read_bytes(), source.read_bytes())


if __name__ == "__main__":
  unittest.main()
