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
    """responses: (model, output_tokens, seconds[, ttft, think]) — each one a request→response pair.

    With ttft/think the response opens with a thinking block, the way CC stamps it: the block's
    line lands when thinking ends and carries thinkingDurationMs, so first token = stamp - think.
    """
    lines = []
    clock = 0.0
    for index, (model, out, seconds, *thinking) in enumerate(responses):
      lines.append({"type": "user", "timestamp": iso(clock), "message": {"role": "user", "content": "go"}})
      if thinking:
        ttft, think = thinking
        chunks = [
          (clock + ttft + think, [{"type": "thinking"}], {"thinkingDurationMs": think * 1000}),
          (clock + seconds, [{"type": "text"}], {}),
        ]
      else:
        # Two chunks per response, like CC writes one line per content block.
        chunks = [(clock + seconds / 2, [{"type": "text"}], {}), (clock + seconds, [{"type": "text"}], {})]
      for chunk_at, content, extra in chunks:
        lines.append({
          "type": "assistant",
          "timestamp": iso(chunk_at),
          "message": {"id": f"msg_{index}", "model": model, "content": content, "usage": {"output_tokens": out}},
          **extra,
        })
      clock += seconds + 1
    path = self.root / "transcript.jsonl"
    path.write_text("".join(json.dumps(line) + "\n" for line in lines))
    self.input["transcript_path"] = str(path)

  def read_log(self):
    month = datetime.now().strftime("%Y-%m")
    log_path = self.home / ".claude" / "projects" / "widget-log" / f"{month}.jsonl"
    return json.loads(log_path.read_text().splitlines()[-1])

  def test_model_pill_shows_decode_speed_and_time_to_first_token(self):
    self.write_transcript([
      ("claude-opus-5-5", 600, 10, 2, 1),
      ("claude-opus-5-5", 800, 10, 2, 1),
      ("claude-opus-5-5", 900, 10, 2, 1),
    ])

    self.assertIn("◆ Test (high) ⚡100 t/s ⏱ 2.0s", self.run_wrapper())

  def test_long_wait_shows_whole_seconds(self):
    self.write_transcript([("gpt-6-astra", 400, 30, 19, 0.002)])

    self.assertIn("⚡13 t/s ⏱ 19s", self.run_wrapper())

  def test_responses_without_thinking_hide_speed(self):
    for model in ("claude-opus-5-5", "gpt-6.1-sol"):
      with self.subTest(model=model):
        self.write_transcript([
          (model, 400, 5),
          (model, 800, 10),
        ])

        output = self.run_wrapper()
        self.assertIn("◆ Test (high)", output)
        self.assertNotIn("⚡", output)
        self.assertNotIn("⏱", output)

  def test_short_responses_are_ignored(self):
    for model in ("claude-opus-5-5", "gpt-6.1-sol"):
      with self.subTest(model=model):
        self.write_transcript([(model, 50, 10, 2, 0.002)])

        self.assertNotIn("⚡", self.run_wrapper())

  def test_batched_thinking_shows_overall_speed_and_wait(self):
    # gpt via the relay hands the whole thinking block over at once, so CC records ~1ms of
    # thinking: the first token is unknowable, and decode speed would count reasoning tokens
    # generated during the wait. Overall speed plus the wait until the block landed is honest.
    self.write_transcript([
      ("gpt-6-astra", 400, 20, 8, 0.001),
      ("gpt-6-astra", 600, 20, 8, 0.001),
    ])

    self.assertIn("◆ Test (high) ⚡25 t/s ⏱ 8.0s", self.run_wrapper())

  def test_gpt_two_millisecond_thinking_uses_overall_speed(self):
    self.write_transcript([
      ("gpt-6.1-sol", 496, 24.760, 24.617, 0.002),
      ("gpt-6.1-sol", 496, 24.760, 24.617, 0.002),
    ])

    self.assertIn("⚡20 t/s ⏱ 25s", self.run_wrapper(log=True))
    entry = self.read_log()
    self.assertEqual(entry["tps"], "20")
    self.assertEqual(entry["tps_decode"], "")
    self.assertEqual(entry["ttft"], "25")

  def test_gpt_overall_speed_does_not_depend_on_thinking_duration(self):
    self.write_transcript([
      ("gpt-6.1-sol", 400, 20, 8, 0.001),
      ("gpt-6.1-sol", 400, 20, 8, 0.002),
      ("gpt-6.1-sol", 400, 20, 8, 0.003),
      ("gpt-6.1-sol", 400, 20, 8, 0.010),
      ("gpt-6.1-sol", 400, 20, 8, 1),
    ])

    self.assertIn("⚡20 t/s ⏱ 8.0s", self.run_wrapper())

  def test_gpt_recent_responses_do_not_reuse_older_decode_samples(self):
    self.write_transcript([
      ("gpt-6.1-sol", 600, 10, 2, 1),
      *[("gpt-6.1-sol", 400, 20, 8, 0.001)] * 5,
    ])

    self.assertIn("⚡20 t/s ⏱ 8.0s", self.run_wrapper())

  def test_gpt_ignores_legacy_speed_cache(self):
    self.write_transcript([
      ("gpt-6.1-sol", 496, 24.760, 24.617, 0.002),
      ("gpt-6.1-sol", 496, 24.760, 24.617, 0.002),
    ])
    path = self.root / "transcript.jsonl"
    stat = path.stat()
    memo = self.widget_cache / "tps2-widget-transcript.jsonl.memo"
    memo.write_text(f"{int(stat.st_mtime)} {stat.st_size}\n20 3468 25 3468\n")

    self.assertIn("⚡20 t/s ⏱ 25s", self.run_wrapper())

  def test_switching_to_gpt_uses_its_overall_speed(self):
    self.write_transcript([
      ("claude-opus-5-5", 600, 10, 2, 1),
      ("gpt-6.1-sol", 496, 24.760, 24.617, 0.002),
    ])

    self.assertIn("⚡20 t/s ⏱ 25s", self.run_wrapper())

  def test_gemini_streamed_thinking_keeps_decode_speed(self):
    self.write_transcript([("gemini-3.7-flash-high", 600, 10, 2, 1)])

    self.assertIn("⚡75 t/s ⏱ 2.0s", self.run_wrapper())

  def test_streamed_thinking_wins_over_batched(self):
    self.write_transcript([
      ("grok-4.7-build", 600, 10, 2, 0.001),
      ("grok-4.7-build", 600, 10, 2, 1),
    ])

    self.assertIn("⚡75 t/s ⏱ 2.0s", self.run_wrapper())

  def test_widget_log_records_batched_wait_without_decode(self):
    self.write_transcript([
      ("gpt-6-astra", 400, 20, 8, 0.001),
      ("gpt-6-astra", 400, 20, 8, 0.001),
    ])

    self.run_wrapper(log=True)

    entry = self.read_log()
    self.assertEqual(entry["tps"], "20")
    self.assertEqual(entry["tps_decode"], "")
    self.assertEqual(entry["ttft"], "8.0")

  def test_only_the_latest_model_counts_after_a_switch(self):
    self.write_transcript([
      ("gpt-6.1-sol", 400, 20, 10, 1),
      ("claude-opus-5-5", 600, 10, 2, 1),
    ])

    self.assertIn("⚡75 t/s ⏱ 2.0s", self.run_wrapper())

  def test_slow_speed_has_no_warning_marker(self):
    self.write_transcript([("gpt-6.1-sol", 400, 30, 19, 0.002)])

    output = self.run_wrapper()
    self.assertIn("⚡13 t/s", output)
    self.assertNotIn("⚠", output.split("⚡", 1)[1].split("\n", 1)[0])

  def test_no_transcript_hides_speed(self):
    output = self.run_wrapper()

    self.assertIn("◆ Test (high)", output)
    self.assertNotIn("⚡", output)

  def test_widget_log_keeps_end_to_end_tps_and_adds_decode_and_ttft(self):
    self.write_transcript([
      ("claude-opus-5-5", 400, 5),
      ("claude-opus-5-5", 400, 5),
    ])

    self.run_wrapper(log=True)

    entry = self.read_log()
    self.assertEqual(entry["tps"], "80")
    self.assertEqual(entry["tps_decode"], "")
    self.assertEqual(entry["ttft"], "")

  def test_widget_log_records_decode_and_ttft(self):
    self.write_transcript([
      ("claude-opus-5-5", 600, 10, 2, 1),
      ("claude-opus-5-5", 600, 10, 2, 1),
    ])

    self.run_wrapper(log=True)

    entry = self.read_log()
    self.assertEqual(entry["tps"], "60")
    self.assertEqual(entry["tps_decode"], "75")
    self.assertEqual(entry["ttft"], "2.0")

if __name__ == "__main__":
  unittest.main()
