class PreserveUnknownMedelementProviderCommands < ActiveRecord::Migration[7.1]
  LEGACY_UNFINISHED_STATUSES = %w[
    awaiting_confirmation awaiting_patient_selection awaiting_patient_creation awaiting_phone_refresh
    queued processing reconciliation_required provider_status_unknown
  ].freeze
  VERSIONED_UNFINISHED_STATUSES = LEGACY_UNFINISHED_STATUSES.map { |status| "v2_#{status}" }.freeze
  UNFINISHED_STATUS_PREDICATE =
    "status IN (#{(LEGACY_UNFINISHED_STATUSES + VERSIONED_UNFINISHED_STATUSES).map { |status| "'#{status}'" }.join(', ')})".freeze
  PREVIOUS_UNFINISHED_STATUS_PREDICATE =
    "status IN (#{(LEGACY_UNFINISHED_STATUSES - ['provider_status_unknown'] +
                    VERSIONED_UNFINISHED_STATUSES - ['v2_provider_status_unknown']).map { |status| "'#{status}'" }.join(', ')})".freeze
  PATIENT_IDENTITY_PREDICATE = <<~SQL.squish.freeze
    contact_id IS NOT NULL AND (
      operation IN ('create_patient', 'update_patient') OR
      (operation = 'create_reception' AND (provider_patient_code IS NULL OR provider_patient_code = ''))
    )
  SQL
  APPOINTMENT_INDEX = 'idx_medelement_commands_unfinished_appointment'.freeze
  PATIENT_IDENTITY_INDEX = 'idx_medelement_commands_unfinished_patient_identity'.freeze

  def up
    replace_indexes!(UNFINISHED_STATUS_PREDICATE)
  end

  def down
    # Serialize the precondition check with command writes so an unknown row
    # cannot appear between the count and the index replacement.
    execute 'LOCK TABLE medelement_provider_commands IN SHARE ROW EXCLUSIVE MODE'
    unknown_count = select_value(<<~SQL.squish).to_i
      SELECT COUNT(*)
      FROM medelement_provider_commands
      WHERE status IN ('provider_status_unknown', 'v2_provider_status_unknown')
    SQL
    if unknown_count.positive?
      raise ActiveRecord::MigrationError,
            "Cannot remove provider-status-unknown barriers while #{unknown_count} command(s) remain unresolved"
    end

    replace_indexes!(PREVIOUS_UNFINISHED_STATUS_PREDICATE)
  end

  private

  def replace_indexes!(status_predicate)
    remove_index :medelement_provider_commands, name: APPOINTMENT_INDEX, if_exists: true
    remove_index :medelement_provider_commands, name: PATIENT_IDENTITY_INDEX, if_exists: true

    add_index :medelement_provider_commands, [:account_id, :appointment_id],
              unique: true,
              where: "appointment_id IS NOT NULL AND #{status_predicate}",
              name: APPOINTMENT_INDEX
    add_index :medelement_provider_commands, [:account_id, :contact_id],
              unique: true,
              where: "#{PATIENT_IDENTITY_PREDICATE} AND #{status_predicate}",
              name: PATIENT_IDENTITY_INDEX
  end
end
