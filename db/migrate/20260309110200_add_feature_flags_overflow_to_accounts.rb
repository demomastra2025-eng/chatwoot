# frozen_string_literal: true

class AddFeatureFlagsOverflowToAccounts < ActiveRecord::Migration[7.1]
  def up
    add_column :accounts, :feature_flags_overflow, :jsonb, default: [], null: false unless column_exists?(:accounts, :feature_flags_overflow)

    execute <<~SQL.squish
      UPDATE accounts
      SET feature_flags_overflow = feature_flags_overflow
        || CASE WHEN feature_flags_overflow ? 'scheduling' THEN '[]'::jsonb ELSE '["scheduling"]'::jsonb END
        || CASE WHEN feature_flags_overflow ? 'scheduling_finance' THEN '[]'::jsonb ELSE '["scheduling_finance"]'::jsonb END,
          updated_at = NOW()
      WHERE NOT (feature_flags_overflow @> '["scheduling", "scheduling_finance"]'::jsonb)
    SQL
  end

  def down
    return unless column_exists?(:accounts, :feature_flags_overflow)

    # Existing installations may already have this column; its origin cannot be proven on rollback.
    raise ActiveRecord::IrreversibleMigration, 'Cannot safely discard account overflow flags'
  end
end
