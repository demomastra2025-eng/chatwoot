class BackfillFeatureContactAttributesForAssistants < ActiveRecord::Migration[7.1]
  # Position 47 in the preserved feature_flags bitmask (Featurable::LEGACY_BITMASK_FEATURE_NAMES).
  CAPTAIN_INTEGRATION_V2_FLAG = 1 << 46

  def up
    return unless ChatwootApp.enterprise?
    # An installed schema may have already run the later migration that removes this legacy key.
    return if select_value("SELECT 1 FROM schema_migrations WHERE version = '20260406143000' LIMIT 1")

    execute <<~SQL.squish
      UPDATE captain_assistants
      SET config = jsonb_set(captain_assistants.config, '{feature_contact_attributes}', 'true'::jsonb),
          updated_at = NOW()
      FROM accounts
      WHERE captain_assistants.account_id = accounts.id
        AND (accounts.feature_flags & #{CAPTAIN_INTEGRATION_V2_FLAG}) <> 0
        AND jsonb_typeof(captain_assistants.config) = 'object'
        AND NOT (captain_assistants.config ? 'feature_contact_attributes')
    SQL
  end

  def down
    return unless ChatwootApp.enterprise?

    # The pre-existing and backfilled true values have no provenance marker.
    raise ActiveRecord::IrreversibleMigration, 'Cannot safely revert assistant contact attribute flags'
  end
end
