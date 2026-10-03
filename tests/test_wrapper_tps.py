import json
import unittest
from datetime import datetime, timedelta, timezone

# Import the module, not the class, so unittest doesn't collect the quota tests here too.
import test_wrapper_quota as quota


BASE = datetime(2026, 10, 3, 1, 0, 0, tzinfo=timezone.utc)


def iso(seconds):
  return (BASE + timedelta(seconds=seconds)).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


class WrapperTpsTests(unittest.TestCase):
  setUp = quota.WrapperQuotaContractTests.setUp
  tearDown = quota.WrapperQuotaContractTests.tearDown
  run_wrapper = quota.WrapperQuotaContractTests.run_wrapper

  def write_transcript(self, responses):
    """responses: (model, output_tokens, seconds) — each one a request→response pair."""
    lines = []
    clock = 0.0
    for index, (model, out, seconds) in enumerate(responses):
      lines.append({"type": "user", "timestamp": iso(clock), "message": {"role": "user", "content": "go"}})
      # Two chunks per response, like CC writes one line per content block.
      for chunk_at in (clock + seconds / 2, clock + seconds):
        lines.append({
          "type": "assistant",
          "timestamp": iso(chunk_at),
          "message": {"id": f"msg_{index}", "model": model, "usage": {"output_tokens": out}}
        })
      clock += seconds + 1
    path = self.root / "transcript.jsonl"
    path.write_text("".join(json.dumps(line) + "\n" for line in lines))
    self.input["transcript_path"] = str(path)

  def test_model_pill_shows_median_speed_of_recent_responses(self):
    self.write_transcript([
      ("claude-opus-5-5", 400, 5),
      ("claude-opus-5-5", 800, 10),
      ("claude-opus-5-5", 900, 10),
    ])

    self.assertIn("◆ Test (high) ⚡80 t/s", self.run_wrapper())

  def test_short_responses_are_ignored_and_too_few_samples_show_dashes(self):
    self.write_transcript([
      ("claude-opus-5-5", 400, 5),
      ("claude-opus-5-5", 50, 10),
    ])

    self.assertIn("◆ Test (high) ⚡-- t/s", self.run_wrapper())

  def test_only_the_latest_model_counts_after_a_switch(self):
    self.write_transcript([
      ("gpt-6.1-sol", 400, 20),
      ("gpt-6.1-sol", 400, 20),
      ("claude-opus-5-5", 600, 10),
      ("claude-opus-5-5", 600, 10),
    ])

    self.assertIn("⚡60 t/s", self.run_wrapper())

  def test_slow_speed_has_no_warning_marker(self):
    self.write_transcript([
      ("gpt-6.1-sol", 400, 20),
      ("gpt-6.1-sol", 400, 20),
    ])

    output = self.run_wrapper()
    self.assertIn("⚡20 t/s", output)
    self.assertNotIn("⚠20", output)

  def test_no_transcript_hides_speed(self):
    output = self.run_wrapper()

    self.assertIn("◆ Test (high)", output)
    self.assertNotIn("⚡", output)

  def test_widget_log_records_tps(self):
    self.write_transcript([
      ("claude-opus-5-5", 400, 5),
      ("claude-opus-5-5", 400, 5),
    ])

    self.run_wrapper(log=True)

    month = datetime.now().strftime("%Y-%m")
    log_path = self.home / ".claude" / "projects" / "widget-log" / f"{month}.jsonl"
    entry = json.loads(log_path.read_text().splitlines()[-1])
    self.assertEqual(entry["tps"], "80")


if __name__ == "__main__":
  unittest.main()
