class VersionMedelementProviderCommandExecution < ActiveRecord::Migration[7.1]
  LEGACY_UNFINISHED_STATUSES = %w[
    awaiting_confirmation awaiting_patient_selection awaiting_patient_creation awaiting_phone_refresh
    queued processing reconciliation_required
  ].freeze
  VERSIONED_UNFINISHED_STATUSES = LEGACY_UNFINISHED_STATUSES.map { |status| "v2_#{status}" }.freeze
  UNFINISHED_STATUS_PREDICATE =
    "status IN (#{(LEGACY_UNFINISHED_STATUSES + VERSIONED_UNFINISHED_STATUSES).map { |status| "'#{status}'" }.join(', ')})".freeze
  LEGACY_STATUS_PREDICATE =
    "status IN (#{LEGACY_UNFINISHED_STATUSES.map { |status| "'#{status}'" }.join(', ')})".freeze
  VERSIONED_STATUS_PREDICATE =
    "status IN (#{VERSIONED_UNFINISHED_STATUSES.map { |status| "'#{status}'" }.join(', ')})".freeze
  PATIENT_IDENTITY_PREDICATE = <<~SQL.squish.freeze
    contact_id IS NOT NULL AND (
      operation IN ('create_patient', 'update_patient') OR
      (operation = 'create_reception' AND (provider_patient_code IS NULL OR provider_patient_code = ''))
    )
  SQL
  APPOINTMENT_INDEX = 'idx_medelement_commands_unfinished_appointment'.freeze
  PATIENT_IDENTITY_INDEX = 'idx_medelement_commands_unfinished_patient_identity'.freeze

  def up
    assert_no_expanded_duplicates!
    replace_indexes!(UNFINISHED_STATUS_PREDICATE)
    version_existing_commands!
  end

  def down
    versioned_count = select_value(<<~SQL.squish).to_i
      SELECT COUNT(*)
      FROM medelement_provider_commands
      WHERE #{VERSIONED_STATUS_PREDICATE}
    SQL
    if versioned_count.positive?
      raise ActiveRecord::MigrationError,
            "Cannot roll back Medelement execution schema while #{versioned_count} versioned command(s) are unfinished"
    end

    replace_indexes!(LEGACY_STATUS_PREDICATE)
  end

  private

  def version_existing_commands!
    execute <<~SQL.squish
      UPDATE medelement_provider_commands
      SET status = 'v2_' || status,
          updated_at = CURRENT_TIMESTAMP
      WHERE #{LEGACY_STATUS_PREDICATE}
        AND (execution_state #>> '{request_snapshot,version}') ~ '^[0-9]+$'
        AND (execution_state #>> '{request_snapshot,version}')::integer >= 2
    SQL
  end

  def assert_no_expanded_duplicates!
    duplicates = appointment_duplicate_groups + patient_identity_duplicate_groups
    return if duplicates.zero?

    raise ActiveRecord::MigrationError,
          "Cannot version Medelement provider commands: #{duplicates} duplicate target group(s) require review"
  end

  def appointment_duplicate_groups
    select_value(<<~SQL.squish).to_i
      SELECT COUNT(*)
      FROM (
        SELECT account_id, appointment_id
        FROM medelement_provider_commands
        WHERE appointment_id IS NOT NULL AND #{UNFINISHED_STATUS_PREDICATE}
        GROUP BY account_id, appointment_id
        HAVING COUNT(*) > 1
      ) duplicates
    SQL
  end

  def patient_identity_duplicate_groups
    select_value(<<~SQL.squish).to_i
      SELECT COUNT(*)
      FROM (
        SELECT account_id, contact_id
        FROM medelement_provider_commands
        WHERE #{PATIENT_IDENTITY_PREDICATE} AND #{UNFINISHED_STATUS_PREDICATE}
        GROUP BY account_id, contact_id
        HAVING COUNT(*) > 1
      ) duplicates
    SQL
  end

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
