"""scripts/ci/dco.py: every non-merge commit in a range carries a sign-off.

Builds a throwaway git repo per test so the range is real history, not a
fixture string.
"""

from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "ci" / "dco.py"


class Fixture(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.git("init", "--quiet", "-b", "main")
        self.git("config", "user.email", "t@example.com")
        self.git("config", "user.name", "t")
        self.commit("base.txt", "base\n", signoff=True)
        self.base = self.git("rev-parse", "HEAD").stdout.strip()

    def git(self, *args):
        return subprocess.run(["git", *args], cwd=self.root, check=True,
                              capture_output=True, text=True)

    def commit(self, name: str, text: str, *, signoff: bool, trailer: str | None = None,
               cleanup: str | None = None, author: str | None = None):
        path = self.root / name
        path.write_text(text)
        self.git("add", "--", name)
        message = name
        if trailer:
            message += f"\n\n{trailer}"
        elif signoff:
            message += "\n\nSigned-off-by: t <t@example.com>"
        args = ["commit", "--quiet"]
        if cleanup:
            args.append(f"--cleanup={cleanup}")
        if author:
            args.append(f"--author={author}")
        args += ["-m", message]
        self.git(*args)
        return self.git("rev-parse", "HEAD").stdout.strip()

    def run_script(self, base: str, head: str = "HEAD", pr_author: str | None = None):
        args = [sys.executable, str(SCRIPT), "--root", str(self.root), "--base", base, "--head", head]
        if pr_author:
            args += ["--pr-author", pr_author]
        return subprocess.run(args, capture_output=True, text=True)


class DcoTest(Fixture):
    def test_all_signed_off_passes(self):
        self.commit("a.txt", "a\n", signoff=True)
        self.commit("b.txt", "b\n", signoff=True)
        result = self.run_script(self.base)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("2 commits judged", result.stdout)

    def test_one_unsigned_commit_fails_and_is_named(self):
        self.commit("a.txt", "a\n", signoff=True)
        sha = self.commit("b.txt", "b\n", signoff=False)
        result = self.run_script(self.base)
        self.assertEqual(result.returncode, 1)
        self.assertIn(sha[:7], result.stderr)
        self.assertIn("b.txt", result.stderr)
        self.assertNotIn("Signed-off-by", result.stdout)

    def test_merge_commit_without_a_trailer_is_skipped(self):
        self.git("checkout", "--quiet", "-b", "feature")
        self.commit("feature.txt", "feature\n", signoff=True)
        self.git("checkout", "--quiet", "main")
        self.commit("main.txt", "main\n", signoff=True)
        self.git("checkout", "--quiet", "feature")
        # A merge commit's own message never gets a sign-off in normal use;
        # the gate must not flag it.
        self.git("merge", "--quiet", "--no-edit", "main")
        result = self.run_script(self.base)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("2 commits judged", result.stdout)

    def test_empty_range_passes(self):
        result = self.run_script(self.base, head=self.base)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("0 commits judged", result.stdout)

    def test_trailer_identity_need_not_match_the_author(self):
        sha = self.commit("a.txt", "a\n", signoff=False,
                           trailer="Signed-off-by: Someone Else <else@example.com>")
        result = self.run_script(self.base)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("1 commit judged", result.stdout)

    def test_a_prose_mention_of_the_trailer_is_not_a_trailer(self):
        # "Signed-off-by: ..." appears in the message but mid-sentence, not
        # as the message's trailing trailer block; a whole-message regex
        # would wrongly accept this.
        sha = self.commit(
            "a.txt", "a\n", signoff=False,
            trailer="Body mentions Signed-off-by: Example <example@example.com> in passing.",
        )
        result = self.run_script(self.base)
        self.assertEqual(result.returncode, 1)
        self.assertIn(sha[:7], result.stderr)

    def test_a_whitespace_only_trailer_value_fails(self):
        # --cleanup=verbatim keeps the trailing whitespace a normal commit
        # would strip, reproducing a trailer with no real value.
        sha = self.commit("a.txt", "a\n", signoff=False,
                           trailer="Signed-off-by:" + "   ", cleanup="verbatim")
        result = self.run_script(self.base)
        self.assertEqual(result.returncode, 1)
        self.assertIn(sha[:7], result.stderr)


DEPENDABOT = "dependabot[bot] <49699333+dependabot[bot]@users.noreply.github.com>"


class DependabotTest(Fixture):
    def test_dependabot_commit_on_a_dependabot_pr_is_exempt(self):
        self.commit("a.txt", "a\n", signoff=False, author=DEPENDABOT)
        result = self.run_script(self.base, pr_author="dependabot[bot]")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("0 commits judged", result.stdout)

    def test_a_human_commit_on_a_dependabot_pr_is_still_judged(self):
        self.commit("a.txt", "a\n", signoff=False, author=DEPENDABOT)
        sha = self.commit("b.txt", "b\n", signoff=False)
        result = self.run_script(self.base, pr_author="dependabot[bot]")
        self.assertEqual(result.returncode, 1)
        self.assertIn(sha[:7], result.stderr)

    def test_a_dependabot_author_on_a_human_pr_is_still_judged(self):
        # The commit author is whatever the pusher typed; only the PR's
        # author, from the GitHub event, grants the exemption.
        sha = self.commit("a.txt", "a\n", signoff=False, author=DEPENDABOT)
        for pr_author in (None, "someone"):
            result = self.run_script(self.base, pr_author=pr_author)
            self.assertEqual(result.returncode, 1, pr_author)
            self.assertIn(sha[:7], result.stderr)


if __name__ == "__main__":
    unittest.main()
