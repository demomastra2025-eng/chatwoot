from contextlib import chdir
from pathlib import Path
import subprocess
import tempfile
import unittest

from script.onelink.change_plan import (
    changed_files,
    classify,
    existing_files_with_suffixes,
    related_specs,
    validate_migrations,
)


class ChangePlanTest(unittest.TestCase):
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

    def test_destructive_down_is_allowed_for_additive_up(self):
        content = """class AddFlag < ActiveRecord::Migration[7.1]
  def up
    add_column :accounts, :flag, :boolean
  end

  def down
    remove_column :accounts, :flag
  end
end
"""

        self.assertEqual(self.validate_migration_content(content), [])

    def test_destructive_change_is_rejected(self):
        content = """class RemoveFlag < ActiveRecord::Migration[7.1]
  def change
    remove_column :accounts, :flag
  end
end
"""

        self.assertEqual(self.validate_migration_content(content), ["db/migrate/test.rb"])

    def test_same_name_concurrent_index_rebuild_is_allowed(self):
        content = """class RepairIndex < ActiveRecord::Migration[7.1]
  INDEX_NAME = 'idx_accounts_on_name'

  def up
    remove_index :accounts, name: INDEX_NAME, algorithm: :concurrently if index_exists?(:accounts, name: INDEX_NAME)
    add_index :accounts, :name,
              name: INDEX_NAME,
              algorithm: :concurrently
  end
end
"""

        self.assertEqual(self.validate_migration_content(content), [])

    def test_concurrent_index_removal_without_rebuild_is_rejected(self):
        content = """class RemoveIndex < ActiveRecord::Migration[7.1]
  def up
    remove_index :accounts, name: 'idx_accounts_on_name', algorithm: :concurrently
  end
end
"""

        self.assertEqual(self.validate_migration_content(content), ["db/migrate/test.rb"])

    def test_destructive_helper_reachable_from_up_is_rejected(self):
        content = """class RetireLegacy < ActiveRecord::Migration[7.1]
  def up
    retire_legacy_schema!
  end

  def down
    restore_legacy_schema!
  end

  private

  def retire_legacy_schema!
    remove_column :accounts, :legacy
  end

  def restore_legacy_schema!
    add_column :accounts, :legacy, :string
  end
end
"""

        self.assertEqual(self.validate_migration_content(content), ["db/migrate/test.rb"])

    def test_destructive_helper_reachable_only_from_down_is_allowed(self):
        content = """class AddFlag < ActiveRecord::Migration[7.1]
  def up
    add_flag!
  end

  def down
    remove_flag!
  end

  private

  def add_flag!
    add_column :accounts, :flag, :boolean
  end

  def remove_flag!
    remove_column :accounts, :flag
  end
end
"""

        self.assertEqual(self.validate_migration_content(content), [])

    def test_commented_out_rebuild_does_not_allow_index_removal(self):
        content = """class RemoveIndex < ActiveRecord::Migration[7.1]
  def up
    remove_index :accounts, name: 'idx_accounts_on_name', algorithm: :concurrently
    # add_index :accounts, :name, name: 'idx_accounts_on_name', algorithm: :concurrently
  end
end
"""

        self.assertEqual(self.validate_migration_content(content), ["db/migrate/test.rb"])

    def test_literal_name_concurrent_index_rebuild_is_allowed(self):
        content = """class RepairIndex < ActiveRecord::Migration[7.1]
  def up
    remove_index :accounts, name: 'idx_accounts_on_name', algorithm: :concurrently
    add_index :accounts, :name, name: 'idx_accounts_on_name', algorithm: :concurrently
  end
end
"""

        self.assertEqual(self.validate_migration_content(content), [])

    def test_destructive_raw_sql_is_rejected(self):
        content = """class DropLegacy < ActiveRecord::Migration[7.1]
  def up
    connection.execute('DROP TABLE legacy_accounts')
  end
end
"""

        self.assertEqual(self.validate_migration_content(content), ["db/migrate/test.rb"])

    def test_same_name_concurrent_sql_index_rebuild_is_allowed(self):
        content = """class RepairIndex < ActiveRecord::Migration[7.1]
  INDEX_NAME = 'idx_accounts_on_name'

  def up
    connection.execute \"DROP INDEX CONCURRENTLY IF EXISTS #{INDEX_NAME}\"
    connection.execute \"CREATE INDEX CONCURRENTLY #{INDEX_NAME} ON accounts (name)\"
  end
end
"""

        self.assertEqual(self.validate_migration_content(content), [])

    def test_concurrent_sql_index_drop_without_rebuild_is_rejected(self):
        content = """class RemoveIndex < ActiveRecord::Migration[7.1]
  def up
    connection.execute('DROP INDEX CONCURRENTLY IF EXISTS idx_accounts_on_name')
  end
end
"""

        self.assertEqual(self.validate_migration_content(content), ["db/migrate/test.rb"])

    def test_helper_add_before_helper_remove_is_rejected(self):
        content = """class RemoveIndex < ActiveRecord::Migration[7.1]
  def up
    add_replacement!
    remove_original!
  end

  def add_replacement!
    add_index :accounts, :name, name: 'idx_accounts_on_name', algorithm: :concurrently
  end

  def remove_original!
    remove_index :accounts, name: 'idx_accounts_on_name', algorithm: :concurrently
  end
end
"""

        self.assertEqual(self.validate_migration_content(content), ["db/migrate/test.rb"])

    def test_add_index_options_from_different_calls_do_not_form_rebuild(self):
        content = """class RemoveIndex < ActiveRecord::Migration[7.1]
  def up
    remove_index :accounts, name: 'idx_accounts_on_name', algorithm: :concurrently
    add_index :accounts, :name, name: 'idx_accounts_on_name'
    add_index :accounts, :created_at, name: 'idx_accounts_on_created_at', algorithm: :concurrently
  end
end
"""

        self.assertEqual(self.validate_migration_content(content), ["db/migrate/test.rb"])

    def test_non_executed_sql_create_does_not_form_rebuild(self):
        content = """class RemoveIndex < ActiveRecord::Migration[7.1]
  def up
    connection.execute('DROP INDEX CONCURRENTLY IF EXISTS idx_accounts_on_name')
    sql = 'CREATE INDEX CONCURRENTLY idx_accounts_on_name ON accounts (name)'
  end
end
"""

        self.assertEqual(self.validate_migration_content(content), ["db/migrate/test.rb"])

    def validate_migration_content(self, content):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            migration = root / "db/migrate/test.rb"
            migration.parent.mkdir(parents=True)
            migration.write_text(content, encoding="utf-8")
            with chdir(root):
                return validate_migrations([migration.relative_to(root).as_posix()])


if __name__ == "__main__":
    unittest.main()
