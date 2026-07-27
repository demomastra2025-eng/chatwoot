class CreateMedelementProviderCommands < ActiveRecord::Migration[7.1]
  UNFINISHED_STATUS_PREDICATE =
    "status IN ('awaiting_confirmation', 'queued', 'processing', 'reconciliation_required')".freeze
  PATIENT_IDENTITY_PREDICATE =
    <<~SQL.squish.freeze
      contact_id IS NOT NULL AND (
        operation IN ('create_patient', 'update_patient') OR
        (operation = 'create_reception' AND (provider_patient_code IS NULL OR provider_patient_code = ''))
      )
    SQL

  # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
  def change
    create_table :medelement_provider_commands do |t|
      t.references :account, null: false, foreign_key: { on_delete: :cascade }
      t.references :hook, null: true, foreign_key: { to_table: :integrations_hooks, on_delete: :nullify }
      t.references :appointment, null: true, foreign_key: { to_table: :scheduling_appointments, on_delete: :nullify }
      t.references :contact, null: true, foreign_key: { on_delete: :nullify }
      t.references :confirmation_request, null: true, foreign_key: { on_delete: :nullify }
      t.references :requested_by, null: true, foreign_key: { to_table: :users, on_delete: :nullify }
      t.string :operation, null: false
      t.string :status, null: false, default: 'awaiting_confirmation'
      t.string :idempotency_key, null: false
      t.string :provider_patient_code
      t.string :provider_reception_code
      t.string :company_cabinet_code
      t.datetime :desired_starts_at
      t.datetime :desired_ends_at
      t.jsonb :execution_state, null: false, default: {}
      t.integer :attempt_count, null: false, default: 0
      t.string :last_error_code
      t.integer :last_error_status
      t.datetime :confirmed_at
      t.datetime :executed_at
      t.timestamps
    end

    add_index :medelement_provider_commands,
              [:account_id, :idempotency_key],
              unique: true,
              name: 'idx_medelement_commands_account_idempotency'
    add_index :medelement_provider_commands, [:hook_id, :status], name: 'idx_medelement_commands_hook_status'
    add_index :medelement_provider_commands, [:appointment_id, :status], name: 'idx_medelement_commands_appointment_status'
    add_index :medelement_provider_commands, [:account_id, :appointment_id],
              unique: true,
              where: "appointment_id IS NOT NULL AND #{UNFINISHED_STATUS_PREDICATE}",
              name: 'idx_medelement_commands_unfinished_appointment'
    add_index :medelement_provider_commands, [:account_id, :contact_id],
              unique: true,
              where: "#{PATIENT_IDENTITY_PREDICATE} AND #{UNFINISHED_STATUS_PREDICATE}",
              name: 'idx_medelement_commands_unfinished_patient_identity'
  end
  # rubocop:enable Metrics/AbcSize, Metrics/MethodLength
end
