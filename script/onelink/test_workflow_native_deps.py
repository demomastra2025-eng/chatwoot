"""OneLink CI jobs that run RSpec must provide the native libraries the specs load.

The WhatsApp Opus decoder specs call the real libopus through Fiddle
(spec/support/whatsapp_opus_fixtures.rb) and deliberately fail instead of
skipping when it is missing. GitHub-hosted runners do not ship libopus, so every
RSpec job installs it and proves that it loads before the suite starts.
"""

from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
WORKFLOWS = ROOT / ".github" / "workflows"
RSPEC_COMMAND = "bundle exec rspec"
INSTALL_PATTERN = re.compile(
    r"^[ \t]*sudo apt-get\b.*\binstall\b.*\blibopus0\b", re.MULTILINE
)
LOAD_PROBE = 'Fiddle.dlopen("libopus.so.0")'
FIXTURE_LOAD = "Fiddle.dlopen('libopus.so.0')"
JOB_PATTERN = re.compile(r"^  ([A-Za-z0-9_-]+):[ \t]*$", re.MULTILINE)
EXPECTED_RSPEC_JOBS = {
    "onelink_nightly.yml:backend",
    "onelink_pr_gate.yml:backend",
    "onelink_release.yml:release-gate",
}


def workflow_jobs(path: Path) -> dict[str, str]:
    _, separator, body = path.read_text(encoding="utf-8").partition("\njobs:\n")
    if not separator:
        return {}
    starts = list(JOB_PATTERN.finditer(body))
    jobs = {}
    for index, match in enumerate(starts):
        end = starts[index + 1].start() if index + 1 < len(starts) else len(body)
        jobs[match.group(1)] = body[match.start() : end]
    return jobs


def rspec_jobs() -> dict[str, str]:
    jobs = {}
    for path in sorted(WORKFLOWS.glob("onelink_*.yml")):
        for name, text in workflow_jobs(path).items():
            if RSPEC_COMMAND in text:
                jobs[f"{path.name}:{name}"] = text
    return jobs


class WorkflowNativeDependencyTest(unittest.TestCase):
    def test_every_known_rspec_job_is_covered(self):
        self.assertTrue(EXPECTED_RSPEC_JOBS.issubset(set(rspec_jobs())))

    def test_rspec_jobs_install_and_load_libopus_before_rspec(self):
        for job, text in rspec_jobs().items():
            with self.subTest(job=job):
                rspec = text.index(RSPEC_COMMAND)
                install = INSTALL_PATTERN.search(text)
                self.assertIsNotNone(install, "libopus0 is not installed")
                probe = text.find(LOAD_PROBE)
                self.assertNotEqual(probe, -1, "libopus.so.0 is not load-probed")
                self.assertLess(install.start(), probe)
                self.assertLess(probe, rspec)

    def test_probe_loads_the_library_the_specs_load(self):
        fixture = ROOT / "spec" / "support" / "whatsapp_opus_fixtures.rb"
        self.assertIn(FIXTURE_LOAD, fixture.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
