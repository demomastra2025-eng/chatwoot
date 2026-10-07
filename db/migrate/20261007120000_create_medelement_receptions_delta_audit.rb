class CreateMedelementReceptionsDeltaAudit < ActiveRecord::Migration[7.2]
  def change
    create_cursors
    create_seen_receptions
    create_candidates
    create_misses
  end

  private

  def create_cursors
    create_table :medelement_sync_cursors do |t|
      t.references :hook, null: false, foreign_key: { to_table: :integrations_hooks, on_delete: :cascade }
      t.string :name, null: false
      t.datetime :value
      t.datetime :last_poll_at
      t.datetime :last_success_at
      t.integer :current_interval_seconds
      t.timestamps
    end
    add_index :medelement_sync_cursors, [:hook_id, :name], unique: true
  end

  def create_seen_receptions
    create_table :medelement_delta_seen_receptions do |t|
      t.references :hook, null: false, foreign_key: { to_table: :integrations_hooks, on_delete: :cascade }
      t.string :reception_code, null: false
      t.string :change_marker, null: false
      t.datetime :processed_at, null: false
      t.timestamps
    end
    add_index :medelement_delta_seen_receptions, [:hook_id, :reception_code, :change_marker],
              unique: true, name: 'idx_medelement_delta_seen_identity'
    add_index :medelement_delta_seen_receptions, :processed_at
  end

  def create_candidates
    create_table :medelement_delta_miss_candidates do |t|
      t.references :hook, null: false, foreign_key: { to_table: :integrations_hooks, on_delete: :cascade }
      t.references :full_sweep_run, foreign_key: { to_table: :medelement_sync_runs, on_delete: :nullify }
      t.string :reception_code, null: false
      t.string :kind, null: false
      t.string :change_marker, null: false
      t.jsonb :changed_fields, null: false, default: []
      t.datetime :detected_at, null: false
      t.integer :delta_cursor_age_seconds
      t.timestamps
    end
    add_index :medelement_delta_miss_candidates, [:hook_id, :reception_code, :kind, :change_marker],
              unique: true, name: 'idx_medelement_delta_candidate_identity'
  end

  def create_misses
    create_table :medelement_delta_misses do |t|
      t.references :hook, null: false, foreign_key: { to_table: :integrations_hooks, on_delete: :cascade }
      t.references :full_sweep_run, foreign_key: { to_table: :medelement_sync_runs, on_delete: :nullify }
      t.string :reception_code, null: false
      t.string :kind, null: false
      t.string :change_marker, null: false
      t.string :classification, null: false
      t.jsonb :changed_fields, null: false, default: []
      t.datetime :detected_at, null: false
      t.integer :delta_cursor_age_seconds
      t.timestamps
    end
    add_index :medelement_delta_misses, [:hook_id, :reception_code, :kind, :change_marker],
              unique: true, name: 'idx_medelement_delta_miss_identity'
    add_index :medelement_delta_misses, [:hook_id, :detected_at]
  end
end
