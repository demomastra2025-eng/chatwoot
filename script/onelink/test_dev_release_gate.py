#!/usr/bin/env python3

import contextlib
import hashlib
import io
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from dev_release_gate import ContractManifest, GateError, evaluate, read_live_sha


def run(repo: Path, *args: str) -> str:
    return subprocess.run(
        ["git", "-C", str(repo), *args],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()


class DevReleaseGateTest(unittest.TestCase):
    def setUp(self):
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.repo = Path(self.temporary_directory.name)
        run(self.repo, "init", "-b", "main")
        run(self.repo, "config", "user.email", "gate-test@one-link.kz")
        run(self.repo, "config", "user.name", "DEV release gate test")
        self.write("README.md", "base\n")
        self.write("app/services/integrations/medelement/contract.rb", "baseline contract\n")
        self.write("spec/contracts/medelement_spec.rb", "contract spec\n")
        self.commit("base")
        self.base_sha = self.sha()
        self.manifest = ContractManifest(
            required_ancestor=self.base_sha,
            protected_files={
                "app/services/integrations/medelement/contract.rb": hashlib.sha256(b"baseline contract\n").hexdigest()
            },
            contract_specs=("spec/contracts/medelement_spec.rb",),
        )

        run(self.repo, "switch", "-c", "live")
        self.write("app/services/integrations/medelement/functional.rb", "functional change\n")
        self.write("app/services/integrations/medelement/contract.rb", "live contract\n")
        self.commit("functional change")
        self.live_sha = self.sha()

        run(self.repo, "switch", "-c", "candidate", self.base_sha)
        self.write("script/onelink/deployment_fix.sh", "deployment fix\n")
        self.commit("deployment fix")
        self.divergent_sha = self.sha()

    def tearDown(self):
        self.temporary_directory.cleanup()

    def write(self, relative_path: str, content: str):
        path = self.repo / relative_path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")

    def commit(self, message: str):
        run(self.repo, "add", ".")
        run(self.repo, "commit", "-m", message)

    def sha(self) -> str:
        return run(self.repo, "rev-parse", "HEAD")

    def evaluate(self, candidate_sha: str, allow_rollback: bool = False):
        with contextlib.redirect_stdout(io.StringIO()):
            return evaluate(self.repo, self.live_sha, candidate_sha, allow_rollback=allow_rollback, manifest=self.manifest)

    def test_rejects_divergent_candidate_that_drops_live_functionality(self):
        with self.assertRaisesRegex(GateError, "divergent/non-descendant"):
            self.evaluate(self.divergent_sha)

    def test_accepts_merge_candidate_that_descends_from_live(self):
        run(self.repo, "merge", "--no-ff", "live", "-m", "merge live functionality")

        changes = self.evaluate(self.sha())

        self.assertTrue(any("script/onelink/deployment_fix.sh" in change.paths for change in changes))

    def test_requires_explicit_rollback_flag_for_divergent_candidate(self):
        changes = self.evaluate(self.divergent_sha, allow_rollback=True)

        self.assertTrue(any(change.critical for change in changes))

    def test_blocks_descendant_that_deletes_critical_file(self):
        run(self.repo, "merge", "--no-ff", "live", "-m", "merge live functionality")
        run(self.repo, "rm", "app/services/integrations/medelement/functional.rb")
        self.commit("remove provider functionality")

        with self.assertRaisesRegex(GateError, "removes or explicitly reverts"):
            self.evaluate(self.sha())

    def test_blocks_semantic_rollback_hidden_in_an_ordinary_descendant_commit(self):
        run(self.repo, "merge", "--no-ff", "live", "-m", "merge live functionality")
        self.write("app/services/integrations/medelement/contract.rb", "baseline contract\n")
        self.commit("ordinary maintenance change")

        with self.assertRaisesRegex(GateError, "historical protected contract content"):
            self.evaluate(self.sha())

    def test_allows_new_protected_contract_content_and_requires_contract_tests(self):
        run(self.repo, "merge", "--no-ff", "live", "-m", "merge live functionality")
        self.write("app/services/integrations/medelement/contract.rb", "new contract\n")
        self.commit("extend provider contract")
        output = io.StringIO()

        with contextlib.redirect_stdout(output):
            evaluate(self.repo, self.live_sha, self.sha(), manifest=self.manifest)

        self.assertIn("contract_tests_required=true", output.getvalue())

    def test_rejects_a_tampered_contract_baseline_hash(self):
        invalid_manifest = ContractManifest(
            required_ancestor=self.base_sha,
            protected_files={"app/services/integrations/medelement/contract.rb": "0" * 64},
            contract_specs=("spec/contracts/medelement_spec.rb",),
        )

        with self.assertRaisesRegex(GateError, "baseline hash mismatch"):
            evaluate(self.repo, self.live_sha, self.live_sha, manifest=invalid_manifest)

    def test_blocks_deletion_of_a_manifest_required_contract_spec(self):
        run(self.repo, "merge", "--no-ff", "live", "-m", "merge live functionality")
        run(self.repo, "rm", "spec/contracts/medelement_spec.rb")
        self.commit("remove contract spec")

        with self.assertRaisesRegex(GateError, "missing files required"):
            self.evaluate(self.sha())

    def test_reads_exact_live_sha_marker(self):
        current = self.repo / "current"
        current.mkdir()
        (current / ".git_sha").write_text(f"{self.live_sha}\n", encoding="utf-8")

        self.assertEqual(read_live_sha(current), self.live_sha)


if __name__ == "__main__":
    unittest.main()
