from contextlib import chdir
from pathlib import Path
import subprocess
import tempfile
import unittest

from script.onelink.change_plan import (
    IMMUTABLE_RELEASE_SIDECAR_ROOTS,
    changed_files,
    classify,
    existing_files_with_suffixes,
    frontend_files,
    related_specs,
    unsupported_release_sidecars,
    validate_migrations,
)


class ChangePlanTest(unittest.TestCase):
    def test_only_guarded_uuid_default_restore_is_expand_compatible(self):
        migration_path = "db/migrate/20261004120000_expand_crm_lifecycle_schema.rb"
        other_migration_path = "db/migrate/20261004120001_other.rb"
        guarded_block = """
            correlation_id_column = connection.columns(:crm_stage_visits).find do |column|
              column.name == 'correlation_id'
            end
            raise 'crm_stage_visits.correlation_id is missing' unless correlation_id_column
            actual_uuid_defaults = [correlation_id_column.default, correlation_id_column.default_function]
            has_expected_uuid_default = actual_uuid_defaults.include?('gen_random_uuid()')
            has_no_uuid_default = actual_uuid_defaults.all?(&:nil?)
            if has_no_uuid_default
              change_column_default(:crm_stage_visits, :correlation_id, -> { 'gen_random_uuid()' })
            elsif !has_expected_uuid_default
              raise "Unexpected crm_stage_visits.correlation_id default: #{actual_uuid_defaults.inspect}"
            end
        """
        unexpected_default_branch = (
            '            elsif !has_expected_uuid_default\n'
            '              raise "Unexpected crm_stage_visits.correlation_id default: '
            '#{actual_uuid_defaults.inspect}"\n'
        )
        missing_column_guard = "            raise 'crm_stage_visits.correlation_id is missing' unless correlation_id_column\n"
        cases = [
            (migration_path, guarded_block, []),
            (
                migration_path,
                "change_column_default(:crm_stage_visits, :correlation_id, -> { 'gen_random_uuid()' })\n",
                [migration_path],
            ),
            (
                migration_path,
                "change_column_default(:crm_stage_visits, :correlation_id, nil)\n",
                [migration_path],
            ),
            (
                migration_path,
                guarded_block.replace("connection.columns(:crm_stage_visits)", "connection.columns(:accounts)"),
                [migration_path],
            ),
            (
                migration_path,
                guarded_block.replace("column.name == 'correlation_id'", "column.name == 'id'"),
                [migration_path],
            ),
            (
                migration_path,
                guarded_block.replace(missing_column_guard, ""),
                [migration_path],
            ),
            (
                migration_path,
                guarded_block.replace("correlation_id_column.default_function", ""),
                [migration_path],
            ),
            (
                migration_path,
                guarded_block.replace("has_no_uuid_default = actual_uuid_defaults.all?(&:nil?)", "has_no_uuid_default = false"),
                [migration_path],
            ),
            (
                migration_path,
                guarded_block.replace(
                    "has_expected_uuid_default = actual_uuid_defaults.include?('gen_random_uuid()')",
                    "has_expected_uuid_default = false",
                ),
                [migration_path],
            ),
            (
                migration_path,
                guarded_block.replace(unexpected_default_branch, ""),
                [migration_path],
            ),
            (
                migration_path,
                guarded_block.replace(":crm_stage_visits, :correlation_id", ":accounts, :correlation_id"),
                [migration_path],
            ),
            (
                migration_path,
                guarded_block.replace(
                    ":crm_stage_visits, :correlation_id",
                    ":crm_stage_visits, :owner_id_at_terminal",
                ),
                [migration_path],
            ),
            (
                migration_path,
                guarded_block.replace("'gen_random_uuid()'", "'uuid_generate_v4()'"),
                [migration_path],
            ),
            (
                migration_path,
                guarded_block + "\nremove_column :accounts, :legacy\n",
                [migration_path],
            ),
            (other_migration_path, guarded_block, [other_migration_path]),
        ]

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for migration, content, expected in cases:
                with self.subTest(migration=migration, content=content):
                    path = root / migration
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_text(content, encoding="utf-8")
                    with chdir(root):
                        violations = validate_migrations([migration])

                    self.assertEqual(violations, expected)

        repository_root = Path(__file__).resolve().parents[2]
        with chdir(repository_root):
            violations = validate_migrations([migration_path])

        self.assertEqual(violations, [])

    def test_empty_cli_file_list_has_no_output(self):
        root = Path(__file__).resolve().parents[2]

        result = subprocess.run(
            [
                "python3",
                "script/onelink/change_plan.py",
                "--base",
                "HEAD",
                "--head",
                "HEAD",
                "--list",
                "frontend",
            ],
            cwd=root,
            check=True,
            capture_output=True,
        )

        self.assertEqual(result.stdout, b"")

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

    def test_deleted_files_are_excluded_from_lint_inputs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            existing = root / "app/services/current.rb"
            existing.parent.mkdir(parents=True)
            existing.touch()
            with chdir(root):
                files = existing_files_with_suffixes(
                    ["app/services/current.rb", "app/services/deleted.rb"], {".rb"}
                )

        self.assertEqual(files, ["app/services/current.rb"])

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
        self.assertFalse(plan["frontend"])

    def test_sidecar_javascript_is_not_sent_to_chatwoot_frontend_checks(self):
        self.assertEqual(
            frontend_files(
                [
                    "services/onelink-ai-voice/src/index.js",
                    "app/javascript/dashboard/helper/AnalyticsHelper/index.js",
                ]
            ),
            ["app/javascript/dashboard/helper/AnalyticsHelper/index.js"],
        )

    def test_ai_voice_sidecar_is_covered_by_immutable_release(self):
        self.assertEqual(IMMUTABLE_RELEASE_SIDECAR_ROOTS, ("services/onelink-ai-voice/",))
        self.assertEqual(
            unsupported_release_sidecars(
                [
                    "services/onelink-ai-voice/src/index.js",
                    "services/onelink-ai-voice/Dockerfile",
                ]
            ),
            [],
        )

    def test_unmanaged_sidecars_remain_blocked(self):
        self.assertEqual(
            unsupported_release_sidecars(
                [
                    "enterprise/media-server/src/index.js",
                    "services/onelink-ai-voice-pipecat/app.py",
                ]
            ),
            [
                "enterprise/media-server/src/index.js",
                "services/onelink-ai-voice-pipecat/app.py",
            ],
        )

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

    def test_captain_control_changes_select_model_callback_specs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for spec in ("spec/models/conversation_spec.rb", "spec/enterprise/models/message_spec.rb"):
                (root / spec).parent.mkdir(parents=True, exist_ok=True)
                (root / spec).touch()
            with chdir(root):
                specs = related_specs(["enterprise/app/services/captain/conversation/control_service.rb"])

        self.assertEqual(
            specs, ["spec/enterprise/models/message_spec.rb", "spec/models/conversation_spec.rb"]
        )

    def test_message_callback_changes_select_reply_path_specs(self):
        expected = [
            "spec/enterprise/models/message_spec.rb",
            "spec/listeners/action_cable_listener_spec.rb",
            "spec/listeners/whatsapp_typing_listener_spec.rb",
            "spec/models/conversation_spec.rb",
            "spec/services/messages/update_content_service_spec.rb",
            "spec/services/whatsapp_web/send_on_whatsapp_web_service_spec.rb",
        ]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for spec in expected:
                (root / spec).parent.mkdir(parents=True, exist_ok=True)
                (root / spec).touch()
            with chdir(root):
                specs = related_specs(["enterprise/app/models/enterprise/message.rb"])
                control_specs = related_specs(
                    ["enterprise/app/services/captain/conversation/control_service.rb"]
                )

        self.assertEqual(specs, expected)
        self.assertEqual(
            control_specs,
            ["spec/enterprise/models/message_spec.rb", "spec/models/conversation_spec.rb"],
        )

    def test_deleted_specs_are_excluded_from_related_specs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            existing = root / "spec/services/current_spec.rb"
            existing.parent.mkdir(parents=True)
            existing.touch()
            with chdir(root):
                specs = related_specs(
                    ["spec/services/current_spec.rb", "spec/services/deleted_spec.rb"]
                )

        self.assertEqual(specs, ["spec/services/current_spec.rb"])

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
