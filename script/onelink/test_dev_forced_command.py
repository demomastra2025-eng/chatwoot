#!/usr/bin/env python3
"""Exercise the restricted DEV SSH entrypoint without calling the real deploy service."""

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("dev_forced_command.sh")
DEPLOY = Path(__file__).with_name("deploy_dev_release.sh")
DEPLOY_SCRIPT = "/usr/local/sbin/onelink-dev-deploy-release"
VERIFY_SCRIPT = "/usr/local/sbin/onelink-dev-verify-release"
SHA = "a" * 40


class DevForcedCommandTest(unittest.TestCase):
    def setUp(self):
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary_directory.cleanup)
        directory = Path(self.temporary_directory.name)
        sudo = directory / "sudo"
        sudo.write_text(
            "#!/usr/bin/env python3\n"
            "import json, sys\n"
            "print(json.dumps(sys.argv[1:]))\n",
            encoding="utf-8",
        )
        sudo.chmod(0o755)
        self.path = f"{directory}:{os.environ['PATH']}"

    def run_command(self, command):
        return subprocess.run(
            ["bash", str(SCRIPT)],
            env={**os.environ, "PATH": self.path, "SSH_ORIGINAL_COMMAND": command},
            capture_output=True,
            text=True,
            check=False,
        )

    def test_deploy_without_sha_selects_the_branch_resolving_entrypoint(self):
        result = self.run_command("deploy")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), ["--non-interactive", DEPLOY_SCRIPT])

    def test_existing_pinned_deploy_remains_available_to_ci(self):
        result = self.run_command(f"deploy {SHA}")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), ["--non-interactive", DEPLOY_SCRIPT, SHA])

    def test_rollback_and_verify_remain_pinned(self):
        for command, expected in (
            (f"rollback {SHA}", ["--non-interactive", DEPLOY_SCRIPT, "--allow-rollback", SHA]),
            (f"verify {SHA}", ["--non-interactive", VERIFY_SCRIPT, SHA]),
        ):
            with self.subTest(command=command):
                result = self.run_command(command)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(result.stdout), expected)

    def test_unrecognized_commands_cannot_reach_sudo(self):
        for command in ("", "deploy aset/dev", "deploy --allow-rollback", "deploy abc", "verify", "rollback", f"deploy {SHA} extra"):
            with self.subTest(command=command):
                result = self.run_command(command)
                self.assertEqual(result.returncode, 64)
                self.assertEqual(result.stdout, "")


class DevRevisionSelectionTest(unittest.TestCase):
    """Run the real deploy script's selection and fetch logic against a local Git remote."""

    def setUp(self):
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary_directory.cleanup)
        root = Path(self.temporary_directory.name)
        origin = root / "origin.git"
        self.repo = root / "repo"
        self.git(root, "init", "--bare", str(origin))
        self.git(root, "init", "-b", "onelink-dev", str(self.repo))
        self.git(self.repo, "config", "user.email", "dev-release-test@one-link.kz")
        self.git(self.repo, "config", "user.name", "DEV release test")
        (self.repo / "README.md").write_text("initial\n", encoding="utf-8")
        self.git(self.repo, "add", "README.md")
        self.git(self.repo, "commit", "-m", "onelink-dev")
        self.onelink_sha = self.git(self.repo, "rev-parse", "HEAD")
        self.git(self.repo, "switch", "-c", "aset/dev")
        (self.repo / "README.md").write_text("aset\n", encoding="utf-8")
        self.git(self.repo, "commit", "-am", "aset/dev")
        self.aset_sha = self.git(self.repo, "rev-parse", "HEAD")
        self.git(self.repo, "remote", "add", "origin", str(origin))
        self.git(self.repo, "push", "origin", "onelink-dev", "aset/dev")

        source = DEPLOY.read_text(encoding="utf-8")
        parse = source.split("ALLOW_ROLLBACK=0\n", 1)[1].split("\nROOT=/srv/onelink-dev", 1)[0]
        fetch = source.split('log "fetching canonical ${SOURCE_BRANCH} branch"', 1)[1].split(
            'git -C "${SOURCE_REPO}" verify-commit', 1
        )[0]
        self.selection = (
            "set -euo pipefail\nusage() { exit 64; }\nALLOW_ROLLBACK=0\n"
            + parse
            + '\nlog() { :; }\nlog "fetching canonical ${SOURCE_BRANCH} branch"'
            + fetch
            + '\nprintf "%s %s\\n" "$SOURCE_BRANCH" "$SHA"\n'
        )

    @staticmethod
    def git(directory, *args):
        return subprocess.run(
            ["git", "-C", str(directory), *args], capture_output=True, text=True, check=True
        ).stdout.strip()

    def select(self, *args):
        return subprocess.run(
            ["bash", "-c", self.selection, "release-test", *args],
            env={**os.environ, "SOURCE_REPO": str(self.repo)},
            capture_output=True,
            text=True,
            check=False,
        )

    def test_no_sha_resolves_aset_branch_head(self):
        result = self.select()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), f"aset/dev {self.aset_sha}")

    def test_pinned_ci_sha_resolves_onelink_branch(self):
        result = self.select(self.onelink_sha)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), f"onelink-dev {self.onelink_sha}")

    def test_rejects_noncanonical_and_malformed_requests(self):
        for args, expected_code in (
            ((self.aset_sha,), 65),
            (("invalid",), 64),
            (("",), 64),
            (("--allow-rollback",), 64),
        ):
            with self.subTest(args=args):
                result = self.select(*args)
                self.assertEqual(result.returncode, expected_code, result.stderr)


if __name__ == "__main__":
    unittest.main()
