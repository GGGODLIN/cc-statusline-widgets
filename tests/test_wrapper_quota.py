import json
import os
import re
import shlex
import subprocess
import tempfile
import time
import unittest
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WRAPPER = ROOT / "scripts" / "wrapper.sh"
ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")


class WrapperQuotaContractTests(unittest.TestCase):
  def setUp(self):
    self.temporary = tempfile.TemporaryDirectory()
    self.root = Path(self.temporary.name)
    self.home = self.root / "home"
    self.cache = self.home / ".claude" / "cache"
    self.widget_cache = self.root / "widget-cache"
    self.workspace = self.root / "workspace"
    self.cache.mkdir(parents=True)
    self.widget_cache.mkdir()
    self.workspace.mkdir()
    self.wrapper = self.root / "wrapper.sh"
    source = WRAPPER.read_text()
    original = "CACHE_DIR=/tmp/cc-widget-cache"
    replacement = f"CACHE_DIR={shlex.quote(str(self.widget_cache))}"
    self.assertEqual(source.count(original), 1)
    self.wrapper.write_text(source.replace(original, replacement))
    self.wrapper.chmod(0o755)
    self.theme = self.root / "theme.conf"
    self.theme.write_text('WT_STYLE="lean"\nWT_LAYOUT="fixed"\n')
    self.now = int(time.time())
    self.input = {
      "model": {"display_name": "Test"},
      "effort": {"level": "high"},
      "cost": {"total_cost_usd": 0},
      "workspace": {"current_dir": str(self.workspace)},
      "session_id": "quota-contract",
      "context_window": {
        "used_percentage": 0,
        "context_window_size": 200000,
        "current_usage": {}
      }
    }

  def tearDown(self):
    self.temporary.cleanup()

  def write_json(self, name, payload):
    path = self.cache / name
    path.write_text(json.dumps(payload))
    return path

  def write_raw(self, name, content):
    path = self.cache / name
    path.write_text(content)
    return path

  def codex_cache(self, *, fetched_at=None, used=20, remaining=80, reset_at=None, include_remaining=True):
    weekly = {
      "used_percent": used,
      "reset_at": self.now + 7200 if reset_at is None else reset_at,
      "limit_window_seconds": 604800
    }
    if include_remaining:
      weekly["remaining_percent"] = remaining
    return {
      "fetched_at": self.now if fetched_at is None else fetched_at,
      "data": {"weekly": weekly}
    }

  def write_grok_samples(self, *samples):
    path = self.home / ".cli-proxy-api" / "grok-quota-samples.jsonl"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(json.dumps(s) + "\n" for s in samples))
    return path

  def grok_sample(self, *, pct=4.0, age=60, period_age=3600):
    def iso(epoch, fraction=""):
      return datetime.fromtimestamp(epoch, timezone.utc).strftime("%Y-%m-%dT%H:%M:%S") + fraction + "+00:00"
    return {
      "at": iso(self.now - age),
      "pct": pct,
      "period_start": iso(self.now - period_age, ".254613"),
      "requests": 1,
      "tokens": 100,
      "usd": 0.1
    }

  def run_wrapper(self, *, log=False):
    env = os.environ.copy()
    env.update({
      "HOME": str(self.home),
      "CC_WIDGETS_CONF": str(self.theme),
      "WT_FORCE_COLS": "500"
    })
    if log:
      env.pop("WT_NO_LOG", None)
    else:
      env["WT_NO_LOG"] = "1"
    result = subprocess.run(
      ["/bin/bash", str(self.wrapper)],
      input=json.dumps(self.input),
      text=True,
      capture_output=True,
      env=env,
      check=True
    )
    return ANSI.sub("", result.stdout)

  def test_codex_normal_uses_local_weekly_and_ignores_legacy(self):
    self.write_json("vendor-codex-local.json", self.codex_cache())
    self.write_json("vendor-codex-deadbeef.json", {
      "fetched_at": self.now + 100,
      "data": {"primary": {"used_percent": 99, "remaining_percent": 1, "reset_at": self.now + 60}}
    })
    self.write_json("vendor-codex-deadbeef.status", {"failed_at": self.now + 200, "reason": "legacy-error"})

    output = self.run_wrapper()

    self.assertIn("GPT: 20% · ", output)
    self.assertNotIn("GPT: 99%", output)
    self.assertNotIn("legacy-error", output)

  def test_codex_null_reset_derives_remaining_and_omits_countdown(self):
    self.write_json("vendor-codex-local.json", self.codex_cache(
      used=25,
      reset_at=None,
      include_remaining=False
    ))
    payload = json.loads((self.cache / "vendor-codex-local.json").read_text())
    payload["data"]["weekly"]["reset_at"] = None
    self.write_json("vendor-codex-local.json", payload)

    output = self.run_wrapper()

    self.assertIn("GPT: 25%", output)
    self.assertNotIn("GPT: 25% ·", output)

  def test_codex_missing_reset_derives_remaining_and_omits_countdown(self):
    payload = self.codex_cache(used=25, include_remaining=False)
    del payload["data"]["weekly"]["reset_at"]
    self.write_json("vendor-codex-local.json", payload)

    output = self.run_wrapper()

    self.assertIn("GPT: 25%", output)
    self.assertNotIn("GPT: 25% ·", output)

  def test_codex_rejects_malformed_non_null_reset_times(self):
    for reset_at in [False, "soon", {}, []]:
      with self.subTest(reset_at=reset_at):
        self.write_json("vendor-codex-local.json", self.codex_cache(reset_at=reset_at))

        output = self.run_wrapper()

        self.assertIn("GPT: invalid cache", output)

  def test_codex_newer_status_overrides_cache(self):
    self.write_json("vendor-codex-local.json", self.codex_cache(fetched_at=self.now - 2))
    self.write_json("vendor-codex-local.status", {"failed_at": self.now - 1, "reason": "rate-limited"})

    output = self.run_wrapper()

    self.assertIn("GPT: rate-limited", output)
    self.assertNotIn("GPT: 20%", output)

  def test_codex_equal_timestamp_status_overrides_cache(self):
    self.write_json("vendor-codex-local.json", self.codex_cache(fetched_at=self.now))
    self.write_json("vendor-codex-local.status", {"failed_at": self.now, "reason": "rate-limited"})

    output = self.run_wrapper()

    self.assertIn("GPT: rate-limited", output)
    self.assertNotIn("GPT: 20%", output)

  def test_codex_older_status_is_ignored(self):
    self.write_json("vendor-codex-local.json", self.codex_cache(fetched_at=self.now))
    self.write_json("vendor-codex-local.status", {"failed_at": self.now - 1, "reason": "old-error"})

    output = self.run_wrapper()

    self.assertIn("GPT: 20% · ", output)
    self.assertNotIn("old-error", output)

  def test_codex_stale_cache_shows_stale(self):
    self.write_json("vendor-codex-local.json", self.codex_cache(fetched_at=self.now - 91))

    output = self.run_wrapper()

    self.assertIn("GPT: stale", output)
    self.assertNotIn("GPT: 20%", output)

  def test_codex_invalid_json_shows_invalid_cache(self):
    self.write_raw("vendor-codex-local.json", "{")

    output = self.run_wrapper()

    self.assertIn("GPT: invalid cache", output)

  def test_codex_rejects_inconsistent_non_numeric_and_out_of_range_percentages(self):
    cases = [
      {"used_percent": 20, "remaining_percent": 70},
      {"used_percent": "20", "remaining_percent": 80},
      {"used_percent": -1, "remaining_percent": 101},
      {"used_percent": 20, "remaining_percent": 101}
    ]
    for weekly in cases:
      with self.subTest(weekly=weekly):
        weekly["reset_at"] = self.now + 7200
        weekly["limit_window_seconds"] = 604800
        self.write_json("vendor-codex-local.json", {
          "fetched_at": self.now,
          "data": {"weekly": weekly}
        })
        output = self.run_wrapper()
        self.assertIn("GPT: invalid cache", output)

  def test_codex_status_only_shows_fixed_reason(self):
    self.write_json("vendor-codex-local.status", {"failed_at": self.now, "reason": "unauthorized"})

    output = self.run_wrapper()

    self.assertIn("GPT: unauthorized", output)

  def test_codex_producer_session_only_weekly_null_hides_pill_and_logs_empty_fields(self):
    self.write_json("vendor-codex-local.json", {
      "fetched_at": self.now,
      "data": {
        "plan_type": "plus",
        "session": {
          "used_percent": 20,
          "remaining_percent": 80,
          "limit_window_seconds": 18000,
          "reset_at": self.now + 3600
        },
        "weekly": None,
        "additional_rate_limits": [],
        "credits": None
      }
    })

    output = self.run_wrapper(log=True)

    self.assertNotIn("GPT:", output)
    month = datetime.now().strftime("%Y-%m")
    log_path = self.home / ".claude" / "projects" / "widget-log" / f"{month}.jsonl"
    entry = json.loads(log_path.read_text().splitlines()[-1])
    self.assertEqual(entry["codex_weekly_remaining_pct"], "")
    self.assertEqual(entry["codex_weekly_used_pct"], "")
    self.assertEqual(entry["codex_weekly_reset_at"], "")

  def test_codex_missing_weekly_hides_pill_and_logs_empty_fields(self):
    self.write_json("vendor-codex-local.json", {
      "fetched_at": self.now,
      "data": {
        "session": {
          "used_percent": 20,
          "remaining_percent": 80,
          "limit_window_seconds": 18000,
          "reset_at": self.now + 3600
        }
      }
    })

    output = self.run_wrapper(log=True)

    self.assertNotIn("GPT:", output)
    month = datetime.now().strftime("%Y-%m")
    log_path = self.home / ".claude" / "projects" / "widget-log" / f"{month}.jsonl"
    entry = json.loads(log_path.read_text().splitlines()[-1])
    self.assertEqual(entry["codex_weekly_remaining_pct"], "")
    self.assertEqual(entry["codex_weekly_used_pct"], "")
    self.assertEqual(entry["codex_weekly_reset_at"], "")

  def test_codex_no_files_is_hidden(self):
    output = self.run_wrapper()

    self.assertNotIn("GPT:", output)

  def test_grok_uses_last_sample_with_weekly_countdown(self):
    self.write_grok_samples(self.grok_sample(pct=99.0, age=600), self.grok_sample(pct=4.0, period_age=5400))

    output = self.run_wrapper()

    # period started 1.5h ago, so the weekly reset is 6d22h30m away
    self.assertIn("Grok: 4% · 6d22h", output)
    self.assertNotIn("99%", output)

  def test_grok_stale_sample_is_flagged(self):
    self.write_grok_samples(self.grok_sample(age=901))

    output = self.run_wrapper()

    self.assertIn("Grok: stale", output)
    self.assertNotIn("Grok: 4%", output)

  def test_grok_invalid_sample_is_flagged(self):
    self.write_grok_samples({"at": "nope", "pct": 4.0, "period_start": "nope"})

    output = self.run_wrapper()

    self.assertIn("Grok: invalid cache", output)

  def test_grok_no_samples_is_hidden(self):
    output = self.run_wrapper()

    self.assertNotIn("Grok:", output)

  def grok_bot_cache(self, *, used=0.33, fetched_at=None, reset_in=5400):
    return {
      "fetched_at": self.now if fetched_at is None else fetched_at,
      "data": {"used_percent": used, "reset_at": self.now + reset_in}
    }

  def test_grok_bot_joins_build_in_one_pill(self):
    self.write_grok_samples(self.grok_sample(pct=4.0, period_age=5400))
    self.write_json("vendor-grok-bot-local.json", self.grok_bot_cache(used=12.6, reset_in=6 * 86400 + 5400))

    output = self.run_wrapper()

    self.assertIn("Grok: 4% · 6d22h | Bot: 13% · 6d1h", output)

  def test_grok_bot_alone_keeps_grok_label(self):
    self.write_json("vendor-grok-bot-local.json", self.grok_bot_cache())

    output = self.run_wrapper()

    self.assertIn("Grok Bot: 0% · 1h", output)

  def test_grok_bot_newer_status_shows_reason(self):
    self.write_json("vendor-grok-bot-local.json", self.grok_bot_cache(fetched_at=self.now - 10))
    self.write_json("vendor-grok-bot-local.status", {"failed_at": self.now, "reason": "http-401"})

    output = self.run_wrapper()

    self.assertIn("Bot: http-401", output)
    self.assertNotIn("Bot: 0%", output)

  def test_grok_bot_older_status_is_ignored(self):
    self.write_json("vendor-grok-bot-local.json", self.grok_bot_cache())
    self.write_json("vendor-grok-bot-local.status", {"failed_at": self.now - 10, "reason": "http-401"})

    output = self.run_wrapper()

    self.assertIn("Bot: 0%", output)

  def test_grok_bot_stale_cache_is_flagged(self):
    self.write_json("vendor-grok-bot-local.json", self.grok_bot_cache(fetched_at=self.now - 901))

    output = self.run_wrapper()

    self.assertIn("Bot: stale", output)

  def test_gpt_precedes_grok_and_deepseek_is_gone(self):
    self.write_json("vendor-codex-local.json", self.codex_cache())
    self.write_grok_samples(self.grok_sample())
    self.write_json("vendor-deepseek-local.json", {
      "fetched_at": self.now,
      "data": {"balance_infos": [{"currency": "CNY", "total_balance": "10.00"}]}
    })

    output = self.run_wrapper()

    self.assertLess(output.index("GPT:"), output.index("Grok:"))
    self.assertNotIn("DS:", output)

  def test_gpt_and_grok_use_distinct_backgrounds(self):
    source = WRAPPER.read_text()

    self.assertIn('WT_BG_CODEX=${WT_BG_CODEX:-${WT_BG_VENDOR_LEGACY:-${VL_BG_STYLE:-96}}}', source)
    self.assertIn('WT_BG_GROK=${WT_BG_GROK:-${WT_BG_VENDOR_LEGACY:-${VL_BG_CLOCK:-70,80,110}}}', source)
    self.assertIn('push_seg 2 "$WT_BG_CODEX" "$CODEX_PILL_OUT"', source)
    self.assertIn('push_seg 2 "$WT_BG_GROK" "$grok_seg"', source)

  def test_widget_log_records_grok_fields(self):
    self.write_grok_samples(self.grok_sample(pct=7.9))

    self.run_wrapper(log=True)

    month = datetime.now().strftime("%Y-%m")
    log_path = self.home / ".claude" / "projects" / "widget-log" / f"{month}.jsonl"
    entry = json.loads(log_path.read_text().splitlines()[-1])
    self.assertEqual(entry["grok_weekly_used_pct"], "7")
    self.assertEqual(entry["grok_weekly_reset_at"], str(self.now - 3600 + 604800))
    self.assertEqual(entry["grok_bot_used_pct"], "")

  def test_widget_log_records_grok_bot_fields(self):
    self.write_json("vendor-grok-bot-local.json", self.grok_bot_cache(used=12.6))

    self.run_wrapper(log=True)

    month = datetime.now().strftime("%Y-%m")
    log_path = self.home / ".claude" / "projects" / "widget-log" / f"{month}.jsonl"
    entry = json.loads(log_path.read_text().splitlines()[-1])
    self.assertEqual(entry["grok_bot_used_pct"], "13")
    self.assertEqual(entry["grok_bot_reset_at"], str(self.now + 5400))

  def test_widget_log_has_exact_codex_fields_and_null_reset_values(self):
    self.write_json("vendor-codex-local.json", self.codex_cache(
      used=25,
      reset_at=None,
      include_remaining=False
    ))
    payload = json.loads((self.cache / "vendor-codex-local.json").read_text())
    payload["data"]["weekly"]["reset_at"] = None
    self.write_json("vendor-codex-local.json", payload)

    self.run_wrapper(log=True)

    month = datetime.now().strftime("%Y-%m")
    log_path = self.home / ".claude" / "projects" / "widget-log" / f"{month}.jsonl"
    entry = json.loads(log_path.read_text().splitlines()[-1])
    codex_fields = sorted(key for key in entry if key.startswith("codex_weekly_"))
    self.assertEqual(codex_fields, [
      "codex_weekly_remaining_pct",
      "codex_weekly_reset_at",
      "codex_weekly_used_pct"
    ])
    self.assertEqual(entry["codex_weekly_remaining_pct"], "75")
    self.assertEqual(entry["codex_weekly_used_pct"], "25")
    self.assertEqual(entry["codex_weekly_reset_at"], "")
    self.assertEqual(WRAPPER.read_text().count("--arg codex_weekly_"), 3)


if __name__ == "__main__":
  unittest.main()
