class CreateTelephonyProvisioningRuns < ActiveRecord::Migration[7.0]
  def change
    create_table :telephony_provisioning_runs do |t|
      t.references :account, null: false, foreign_key: { on_delete: :cascade }
      t.references :inbox, foreign_key: { on_delete: :nullify }
      t.bigint :channel_id
      t.references :number_binding, foreign_key: { to_table: :telephony_number_bindings, on_delete: :nullify }
      t.references :provider_connection, foreign_key: { to_table: :telephony_provider_connections, on_delete: :nullify }
      t.string :operation, null: false
      t.string :status, null: false, default: 'pending'
      t.boolean :remote_commit, null: false, default: false
      t.string :idempotency_key, null: false
      t.jsonb :desired_snapshot, null: false, default: {}
      t.jsonb :remote_snapshot, null: false, default: {}
      t.jsonb :planned_operations, null: false, default: []
      t.jsonb :executed_operations, null: false, default: []
      t.string :error_code
      t.text :error_message
      t.jsonb :error_details, null: false, default: {}
      t.references :requested_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.string :request_id
      t.datetime :started_at
      t.datetime :finished_at

      t.timestamps
    end

    add_index :telephony_provisioning_runs, [:account_id, :idempotency_key], unique: true, name: 'idx_tel_provisioning_runs_account_idempotency'
    add_index :telephony_provisioning_runs, [:account_id, :inbox_id, :created_at], name: 'idx_tel_provisioning_runs_account_inbox_created'
    add_index :telephony_provisioning_runs, [:account_id, :status, :created_at], name: 'idx_tel_provisioning_runs_account_status_created'

    add_column :telephony_number_bindings, :provisioning_status, :string, null: false, default: 'local_only'
    add_column :telephony_number_bindings, :last_reconciled_at, :datetime
    add_column :telephony_number_bindings, :remote_drift_detected_at, :datetime
    add_column :telephony_number_bindings, :remote_drift_summary, :jsonb, null: false, default: {}
    add_index :telephony_number_bindings, [:account_id, :provisioning_status], name: 'idx_tel_number_bindings_account_provisioning_status'

    add_column :telephony_provider_connections, :provisioning_status, :string, null: false, default: 'local_only'
    add_column :telephony_provider_connections, :last_reconciled_at, :datetime
    add_column :telephony_provider_connections, :remote_drift_detected_at, :datetime
    add_column :telephony_provider_connections, :remote_drift_summary, :jsonb, null: false, default: {}
    add_index :telephony_provider_connections, [:account_id, :provisioning_status], name: 'idx_tel_provider_connections_account_provisioning_status'
  end
end
