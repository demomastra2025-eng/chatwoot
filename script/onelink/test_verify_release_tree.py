#!/usr/bin/env python3

import contextlib
import io
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from verify_release_tree import verify


def run(repo: Path, *args: str) -> str:
    return subprocess.run(
        ["git", "-C", str(repo), *args],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()


class VerifyReleaseTreeTest(unittest.TestCase):
    def setUp(self):
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)
        self.repo = self.root / "repo"
        self.release = self.root / "release"
        self.repo.mkdir()
        run(self.repo, "init", "-b", "main")
        run(self.repo, "config", "user.email", "tree-test@one-link.kz")
        run(self.repo, "config", "user.name", "Release tree test")
        (self.repo / "app.rb").write_text("puts 'exact'\n", encoding="utf-8")
        nested = self.repo / "config" / "nested"
        nested.mkdir(parents=True)
        (nested / "settings.yml").write_text("exact: true\n", encoding="utf-8")
        executable = self.repo / "script.sh"
        executable.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        executable.chmod(0o755)
        (self.repo / "link").symlink_to("app.rb")
        run(self.repo, "add", ".")
        run(self.repo, "commit", "-m", "exact tree")
        self.sha = run(self.repo, "rev-parse", "HEAD")
        shutil.copytree(self.repo, self.release, symlinks=True, ignore=shutil.ignore_patterns(".git"))

    def tearDown(self):
        self.temporary_directory.cleanup()

    def result(self):
        with contextlib.redirect_stdout(io.StringIO()):
            return verify(self.repo, self.release, self.sha)

    def test_accepts_an_exact_tree_and_ignores_untracked_release_metadata(self):
        (self.release / ".git_sha").write_text(f"{self.sha}\n", encoding="utf-8")

        tracked, _, missing, mismatched = self.result()

        self.assertEqual(tracked, 4)
        self.assertEqual((missing, mismatched), (0, 0))

    def test_reports_missing_and_mismatched_tracked_files(self):
        (self.release / "app.rb").write_text("puts 'changed'\n", encoding="utf-8")
        (self.release / "script.sh").unlink()

        _, _, missing, mismatched = self.result()

        self.assertEqual((missing, mismatched), (1, 1))

    def test_reports_executable_mode_drift(self):
        (self.release / "script.sh").chmod(0o644)

        _, _, missing, mismatched = self.result()

        self.assertEqual((missing, mismatched), (0, 1))


if __name__ == "__main__":
    unittest.main()
