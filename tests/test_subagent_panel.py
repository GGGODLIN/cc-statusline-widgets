import json
import re
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PANEL = ROOT / "scripts" / "subagent-panel.sh"
ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")


class SubagentPanelTests(unittest.TestCase):
  def setUp(self):
    self.temporary = tempfile.TemporaryDirectory()
    self.root = Path(self.temporary.name)
    self.theme = self.root / "theme.conf"
    self.theme.write_text('WT_STYLE="lean"\n')
    self.transcript = self.root / "session.jsonl"
    self.transcript.write_text("")
    self.subagents = self.root / "session" / "subagents"
    self.subagents.mkdir(parents=True)
    self.now_ms = int(time.time() * 1000)

  def tearDown(self):
    self.temporary.cleanup()

  def agent_files(self, task_id, agent_type=None, effort=None):
    # Compact separators: CC writes these files without spaces, and the script matches that.
    dumps = lambda obj: json.dumps(obj, separators=(",", ":"))
    if agent_type is not None:
      (self.subagents / f"agent-{task_id}.meta.json").write_text(dumps({"agentType": agent_type, "spawnDepth": 1}))
    lines = [{"type": "user", "message": {"content": "go"}}]
    if effort is not None:
      lines.append({"type": "assistant", "message": {"model": "claude-sonnet-5-5"}, "effort": effort, "perTurnEffort": effort})
    (self.subagents / f"agent-{task_id}.jsonl").write_text("".join(dumps(l) + "\n" for l in lines))

  def task(self, task_id="a1", **overrides):
    base = {
      "id": task_id, "type": "local_agent", "status": "running",
      "description": "Inventory statusline", "label": "Inventory statusline",
      "startTime": self.now_ms - 105_000, "model": "claude-sonnet-5-5",
      "contextWindowSize": 200000, "tokenCount": 62300, "tokenSamples": [60900, 62300],
    }
    base.update(overrides)
    return base

  def run_panel(self, tasks, columns=200, raw=None):
    payload = raw if raw is not None else json.dumps({
      "session_id": "s", "transcript_path": str(self.transcript), "columns": columns, "tasks": tasks,
    })
    result = subprocess.run(
      ["bash", str(PANEL)], input=payload, capture_output=True, text=True,
      env={"PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin", "HOME": str(self.root),
           "CC_WIDGETS_CONF": str(self.theme)},
      timeout=20,
    )
    self.assertEqual(result.returncode, 0, result.stderr)
    rows = {}
    for line in result.stdout.splitlines():
      obj = json.loads(line)
      rows[obj["id"]] = ANSI.sub("", obj["content"])
    return rows

  def test_running_row_shows_role_model_effort_context_time_and_growth(self):
    self.agent_files("a1", agent_type="deep-explore", effort="high")

    row = self.run_panel([self.task()])["a1"]

    self.assertIn("deep-explore  Inventory statusline", row)
    self.assertIn("◆ Sonnet 5.5 (high)", row)
    self.assertIn("62k/200k", row)
    self.assertIn("▰▰▰▱▱▱▱▱▱▱", row)
    self.assertIn("⧖ 1m45s", row)
    self.assertIn("+1.4k", row)

  def test_narrow_panel_shortens_titles_and_drops_bars_for_every_row(self):
    self.agent_files("a1", agent_type="deep-explore", effort="high")
    self.agent_files("a2", agent_type="url-fetcher", effort="low")
    tasks = [
      self.task("a1", label="Inventory own statusline calc methods and compare them"),
      self.task("a2", label="Fetch docs"),
    ]

    rows = self.run_panel(tasks, columns=70)

    self.assertIn("…", rows["a1"])
    self.assertTrue(rows["a1"].rstrip().endswith("+1.4k"), rows["a1"])
    for row in rows.values():
      self.assertNotIn("▰", row)
      self.assertIn("62k/200k", row)

  def test_role_and_task_are_separate_pills_and_only_the_task_shortens(self):
    self.agent_files("a1", agent_type="deep-explore", effort="high")

    row = self.run_panel([self.task(label="Reading test_subagent_panel.py and more")], columns=80)["a1"]

    self.assertTrue(row.lstrip().startswith("deep-explore  Reading"), row)
    self.assertIn("…", row)

  def test_no_room_for_the_task_drops_it_and_keeps_the_tail(self):
    self.agent_files("a1", agent_type="deep-explore", effort="high")

    row = self.run_panel([self.task(label="Reading files")], columns=55)["a1"]

    self.assertNotIn("Reading", row)
    self.assertTrue(row.rstrip().endswith("+1.4k"), row)

  def test_wide_panel_keeps_full_title(self):
    self.agent_files("a1", agent_type="deep-explore", effort="high")

    row = self.run_panel([self.task(label="Inventory own statusline calc methods")], columns=200)["a1"]

    self.assertIn("deep-explore  Inventory own statusline calc methods", row)
    self.assertNotIn("…", row)

  def test_no_growth_reads_plus_zero_and_one_sample_hides_it(self):
    self.agent_files("a1", agent_type="deep-explore", effort="high")
    self.agent_files("a2", agent_type="deep-explore", effort="high")

    rows = self.run_panel([
      self.task("a1", tokenSamples=[62300, 62300]),
      self.task("a2", tokenSamples=[62300]),
    ])

    self.assertIn("+0", rows["a1"])
    self.assertNotIn("+", rows["a2"].split("⧖", 1)[1])

  def test_finished_rows_show_marks_instead_of_time_and_growth(self):
    self.agent_files("a1", agent_type="skill-verify-auditor", effort="medium")
    self.agent_files("a2", agent_type="url-fetcher")

    rows = self.run_panel([
      self.task("a1", status="completed"),
      self.task("a2", status="failed"),
    ])

    self.assertIn("✓", rows["a1"])
    self.assertNotIn("⧖", rows["a1"])
    self.assertNotIn("+1.4k", rows["a1"])
    self.assertIn("✗", rows["a2"])

  def test_effort_comes_from_the_transcript_not_the_definition(self):
    # The payload's effort is the configured value; the transcript records what was sent.
    self.agent_files("a1", agent_type="deep-explore", effort="medium")

    row = self.run_panel([self.task(effort="max")])["a1"]

    self.assertIn("(medium)", row)
    self.assertNotIn("(max)", row)

  def test_effort_falls_back_to_payload_before_the_first_response(self):
    self.agent_files("a1", agent_type="deep-explore")

    row = self.run_panel([self.task(effort="high")])["a1"]

    self.assertIn("(high)", row)

  def test_model_names_are_shortened(self):
    self.agent_files("a1", agent_type="x", effort="high")
    self.agent_files("a2", agent_type="x")
    self.agent_files("a3", agent_type="x", effort="high")

    rows = self.run_panel([
      self.task("a1", model="claude-opus-5-5[1m]"),
      self.task("a2", model="claude-haiku-4-5-20251001"),
      self.task("a3", model="gpt-5.6-luna"),
    ])

    self.assertIn("◆ Opus 5.5", rows["a1"])
    self.assertIn("◆ Haiku 4.5", rows["a2"])
    self.assertIn("◆ gpt-5.6-luna", rows["a3"])

  def test_rows_other_than_local_agents_keep_cc_rendering(self):
    self.agent_files("a1", agent_type="deep-explore", effort="high")

    rows = self.run_panel([self.task(), {"id": "b1", "type": "local_bash", "status": "running"}])

    self.assertIn("a1", rows)
    self.assertNotIn("b1", rows)

  def test_unknown_agent_type_falls_back_to_name_or_agent(self):
    rows = self.run_panel([self.task("a1"), self.task("a2", name="reviewer")])

    self.assertIn("agent  Inventory statusline", rows["a1"])
    self.assertIn("reviewer  Inventory statusline", rows["a2"])

  def test_bad_input_prints_nothing(self):
    self.assertEqual(self.run_panel([], raw="not json"), {})
    self.assertEqual(self.run_panel([]), {})


if __name__ == "__main__":
  unittest.main()
