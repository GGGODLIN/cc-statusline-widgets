import json
import os
import re
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "usage-color.sh"
ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")

EMAIL = "someone@example.com"
POLL_INTERVAL_SECONDS = 180


def quota_payload():
    return {
        "fetched_at": "14:34:02",
        "email": EMAIL,
        "org_id": "org-1",
        "data": {
            "five_hour": {"utilization": 2, "resets_at": "2026-08-22T18:00:00Z"},
            "seven_day": {"utilization": 6, "resets_at": "2026-08-29T18:00:00Z"},
        },
    }


class AgeThresholdTests(unittest.TestCase):
    def render(self, age_seconds, environment=None):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory) / "home"
            cache = home / ".claude" / "cache"
            cache.mkdir(parents=True)
            payload = cache / f"quota-{EMAIL.replace('@', '_at_')}.json"
            payload.write_text(json.dumps(quota_payload()))
            mtime = time.time() - age_seconds
            os.utime(payload, (mtime, mtime))

            env = os.environ.copy()
            env["HOME"] = str(home)
            env.update(environment or {})
            result = subprocess.run(
                ["/bin/bash", str(SCRIPT)],
                capture_output=True,
                text=True,
                env=env,
            )

        self.assertEqual(result.returncode, 0, result.stderr)
        rendered = ANSI.sub("", result.stdout)
        self.assertIn("2%", rendered, f"segment did not render: {rendered!r}")
        self.assertIn("6%", rendered, f"segment did not render: {rendered!r}")
        return rendered

    def test_fresh_cache_carries_no_age_tag(self):
        rendered = self.render(5)

        self.assertNotIn("old", rendered)
        self.assertNotIn("stale", rendered)

    def test_one_poll_interval_is_not_flagged(self):
        rendered = self.render(POLL_INTERVAL_SECONDS + 5)

        self.assertNotIn("old", rendered)

    def test_two_missed_polls_are_flagged_old(self):
        rendered = self.render(POLL_INTERVAL_SECONDS * 2 + 60)

        self.assertIn("old", rendered)
        self.assertNotIn("stale", rendered)

    def test_three_missed_polls_are_flagged_stale(self):
        rendered = self.render(POLL_INTERVAL_SECONDS * 3 + 90)

        self.assertIn("stale", rendered)

    def test_thresholds_are_overridable(self):
        rendered = self.render(100, {"OLD_AFTER_SECONDS": "60"})

        self.assertIn("old", rendered)


class ThresholdContractTests(unittest.TestCase):
    def read_default(self, name):
        source = SCRIPT.read_text()
        match = re.search(rf"^{name}=\$\{{{name}:-(?P<value>\d+)\}}$", source, re.MULTILINE)
        self.assertIsNotNone(match, f"{name} default not found")
        return int(match.group("value"))

    def test_old_threshold_survives_one_missed_poll(self):
        self.assertGreater(self.read_default("OLD_AFTER_SECONDS"), POLL_INTERVAL_SECONDS * 2)

    def test_stale_threshold_is_later_than_old(self):
        self.assertGreater(
            self.read_default("STALE_AFTER_SECONDS"), self.read_default("OLD_AFTER_SECONDS")
        )


if __name__ == "__main__":
    unittest.main()
