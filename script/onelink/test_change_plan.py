from contextlib import chdir
from pathlib import Path
import subprocess
import tempfile
import unittest

from script.onelink.change_plan import (
    changed_files,
    classify,
    related_specs,
    validate_migrations,
)


class ChangePlanTest(unittest.TestCase):
    def test_deleted_runtime_file_is_included_in_changed_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            subprocess.run(["git", "init", "-q", root], check=True)
            subprocess.run(["git", "-C", root, "config", "user.email", "ci@example.invalid"], check=True)
            subprocess.run(["git", "-C", root, "config", "user.name", "CI"], check=True)
            runtime = root / "app/services/obsolete.rb"
            runtime.parent.mkdir(parents=True)
            runtime.write_text("class Obsolete; end\n", encoding="utf-8")
            subprocess.run(["git", "-C", root, "add", "."], check=True)
            subprocess.run(["git", "-C", root, "commit", "-qm", "add runtime"], check=True)
            base = subprocess.check_output(["git", "-C", root, "rev-parse", "HEAD"], text=True).strip()
            runtime.unlink()
            subprocess.run(["git", "-C", root, "commit", "-qam", "remove runtime"], check=True)
            head = subprocess.check_output(["git", "-C", root, "rev-parse", "HEAD"], text=True).strip()
            with chdir(root):
                files = changed_files(base, head)

        self.assertEqual(files, ["app/services/obsolete.rb"])

    def test_classifies_cross_boundary_change(self):
        plan = classify(
            [
                "app/services/telephony/call_service.rb",
                "app/javascript/dashboard/components/CallPanel.vue",
                "db/migrate/20260912000000_add_call_state.rb",
                "docker/Dockerfile",
            ]
        )

        self.assertEqual(
            plan,
            {
                "backend": True,
                "container": True,
                "frontend": True,
                "high_risk": True,
                "migrations": True,
                "runtime": True,
                "sidecar": False,
            },
        )

    def test_docs_only_change_has_no_runtime_work(self):
        plan = classify(["docs/internal/delivery-pipeline.mdx", "README.md"])

        self.assertFalse(plan["runtime"])
        self.assertFalse(plan["backend"])
        self.assertFalse(plan["frontend"])

    def test_modern_frontend_and_container_configs_are_not_skipped(self):
        plan = classify(
            [
                "app/javascript/dashboard/entrypoint.mjs",
                "vite.config.mts",
                ".dockerignore",
                "docker-compose.test.yml",
            ]
        )

        self.assertTrue(plan["frontend"])
        self.assertTrue(plan["container"])
        self.assertTrue(plan["runtime"])

    def test_embedded_sidecar_is_explicit_release_surface(self):
        plan = classify(["services/onelink-ai-voice/src/index.ts"])

        self.assertTrue(plan["sidecar"])
        self.assertTrue(plan["high_risk"])

    def test_related_specs_maps_app_and_lib_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app_spec = root / "spec/services/example_spec.rb"
            lib_spec = root / "spec/lib/example_spec.rb"
            app_spec.parent.mkdir(parents=True)
            lib_spec.parent.mkdir(parents=True)
            app_spec.touch()
            lib_spec.touch()
            with chdir(root):
                specs = related_specs(["app/services/example.rb", "lib/example.rb"])

        self.assertEqual(specs, ["spec/lib/example_spec.rb", "spec/services/example_spec.rb"])

    def test_destructive_migration_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            migration = root / "db/migrate/20260912000000_remove_legacy.rb"
            migration.parent.mkdir(parents=True)
            migration.write_text("remove_column :accounts, :legacy\n", encoding="utf-8")
            with chdir(root):
                violations = validate_migrations([migration.relative_to(root).as_posix()])

        self.assertEqual(violations, ["db/migrate/20260912000000_remove_legacy.rb"])

    def test_contract_marker_does_not_bypass_automatic_release_gate(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            migration = root / "db/migrate/20260912000000_remove_legacy.rb"
            migration.parent.mkdir(parents=True)
            migration.write_text(
                "# onelink: contract-phase\nremove_column :accounts, :legacy\n",
                encoding="utf-8",
            )
            with chdir(root):
                violations = validate_migrations([migration.relative_to(root).as_posix()])

        self.assertEqual(violations, ["db/migrate/20260912000000_remove_legacy.rb"])


if __name__ == "__main__":
    unittest.main()
