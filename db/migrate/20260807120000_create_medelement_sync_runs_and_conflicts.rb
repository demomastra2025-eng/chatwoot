class CreateMedelementSyncRunsAndConflicts < ActiveRecord::Migration[7.1]
  # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
  def change
    create_table :medelement_sync_runs do |t|
      t.references :account, null: false, foreign_key: { on_delete: :cascade }
      t.references :hook, null: true, foreign_key: { to_table: :integrations_hooks, on_delete: :nullify }
      t.references :requested_by, null: true, foreign_key: { to_table: :users, on_delete: :nullify }
      t.string :trigger, null: false, default: 'scheduled'
      t.string :status, null: false, default: 'queued'
      t.string :current_phase
      t.jsonb :requested_phases, null: false, default: []
      t.jsonb :phase_results, null: false, default: {}
      t.jsonb :summary, null: false, default: {}
      t.string :error_code
      t.text :error_message
      t.datetime :started_at
      t.datetime :completed_at
      t.timestamps
    end

    add_index :medelement_sync_runs, [:hook_id, :created_at], name: 'idx_medelement_sync_runs_hook_created'
    add_index :medelement_sync_runs, [:account_id, :status], name: 'idx_medelement_sync_runs_account_status'
    add_index :medelement_sync_runs,
              :hook_id,
              unique: true,
              where: "hook_id IS NOT NULL AND status IN ('queued', 'running', 'retrying')",
              name: 'idx_medelement_sync_runs_one_active_hook'

    create_table :medelement_sync_conflicts do |t|
      t.references :account, null: false, foreign_key: { on_delete: :cascade }
      t.references :hook, null: true, foreign_key: { to_table: :integrations_hooks, on_delete: :nullify }
      t.references :first_sync_run, null: true, foreign_key: { to_table: :medelement_sync_runs, on_delete: :nullify }
      t.references :last_sync_run, null: true, foreign_key: { to_table: :medelement_sync_runs, on_delete: :nullify }
      t.references :resolved_by, null: true, foreign_key: { to_table: :users, on_delete: :nullify }
      t.string :phase, null: false
      t.string :entity_type, null: false
      t.string :conflict_type, null: false
      t.string :fingerprint, null: false
      t.string :entity_key_digest, null: false
      t.string :severity, null: false, default: 'warning'
      t.string :status, null: false, default: 'open'
      t.jsonb :details, null: false, default: {}
      t.integer :occurrences, null: false, default: 1
      t.datetime :first_seen_at, null: false
      t.datetime :last_seen_at, null: false
      t.datetime :resolved_at
      t.text :resolution_note
      t.timestamps
    end

    add_index :medelement_sync_conflicts,
              [:account_id, :fingerprint],
              unique: true,
              name: 'idx_medelement_sync_conflicts_account_fingerprint'
    add_index :medelement_sync_conflicts,
              [:account_id, :status, :last_seen_at],
              name: 'idx_medelement_sync_conflicts_account_status'
    add_index :medelement_sync_conflicts,
              [:hook_id, :phase, :status],
              name: 'idx_medelement_sync_conflicts_hook_phase_status'
  end
  # rubocop:enable Metrics/AbcSize, Metrics/MethodLength
end
