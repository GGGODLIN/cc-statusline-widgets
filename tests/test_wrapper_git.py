import os
import subprocess
import unittest

# Import the module, not the class, so unittest doesn't collect the quota tests here too.
import test_wrapper_quota as quota

GIT_ENV = {
  **os.environ,
  "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
  "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t",
}


class WrapperGitTests(unittest.TestCase):
  setUp = quota.WrapperQuotaContractTests.setUp
  tearDown = quota.WrapperQuotaContractTests.tearDown
  run_wrapper = quota.WrapperQuotaContractTests.run_wrapper

  def git(self, *args, cwd=None):
    return subprocess.run(
      ["git", "-C", str(cwd or self.workspace), *args],
      env=GIT_ENV, check=True, capture_output=True, text=True,
    ).stdout.strip()

  def init_repo(self):
    self.git("init", "-q", "-b", "main")
    (self.workspace / "a.txt").write_text("a\n")
    self.git("add", "a.txt")
    self.git("commit", "-q", "-m", "init")

  def test_outside_a_repo(self):
    self.assertIn("⎇ no git (no git)", self.run_wrapper())

  def test_clean_repo_without_upstream(self):
    self.init_repo()

    self.assertIn("⎇ main (no upstream)", self.run_wrapper())

  def test_staged_modified_and_untracked_marks(self):
    self.init_repo()
    (self.workspace / "b.txt").write_text("b\n")
    self.git("add", "b.txt")
    (self.workspace / "a.txt").write_text("changed\n")
    (self.workspace / "c.txt").write_text("c\n")

    self.assertIn("⎇ main+!? (no upstream)", self.run_wrapper())

  def test_ahead_and_behind_upstream(self):
    remote = self.root / "remote.git"
    subprocess.run(["git", "init", "-q", "--bare", "-b", "main", str(remote)], check=True)
    self.init_repo()
    self.git("remote", "add", "origin", str(remote))
    self.git("push", "-q", "-u", "origin", "main")
    other = self.root / "other"
    subprocess.run(["git", "clone", "-q", str(remote), str(other)], check=True, env=GIT_ENV)
    (other / "r.txt").write_text("r\n")
    self.git("add", "r.txt", cwd=other)
    self.git("commit", "-q", "-m", "remote", cwd=other)
    self.git("push", "-q", "origin", "main", cwd=other)
    self.git("fetch", "-q", "origin")
    (self.workspace / "l.txt").write_text("l\n")
    self.git("add", "l.txt")
    self.git("commit", "-q", "-m", "local")

    self.assertIn("⎇ main ⇡1⇣1", self.run_wrapper())

  def test_in_sync_upstream_shows_nothing_after_branch(self):
    remote = self.root / "remote.git"
    subprocess.run(["git", "init", "-q", "--bare", "-b", "main", str(remote)], check=True)
    self.init_repo()
    self.git("remote", "add", "origin", str(remote))
    self.git("push", "-q", "-u", "origin", "main")

    output = self.run_wrapper()
    self.assertIn("⎇ main", output)
    self.assertNotIn("(no upstream)", output)
    self.assertNotIn("⇡", output)

  def test_detached_head_shows_short_sha(self):
    self.init_repo()
    sha = self.git("rev-parse", "--short", "HEAD")
    self.git("checkout", "-q", "--detach")

    self.assertIn(f"⎇ {sha} (no upstream)", self.run_wrapper())

  def test_status_never_rewrites_the_index(self):
    # A plain `git status` refreshes stat info and rewrites .git/index under index.lock,
    # which collides with a commit running in the same second. The status line only reads.
    self.init_repo()
    index = self.workspace / ".git" / "index"
    before = index.stat().st_mtime_ns
    os.utime(self.workspace / "a.txt", ns=(before + 5_000_000_000, before + 5_000_000_000))

    self.run_wrapper()

    self.assertEqual(index.stat().st_mtime_ns, before)


if __name__ == "__main__":
  unittest.main()
