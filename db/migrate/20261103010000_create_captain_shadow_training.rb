class CreateCaptainShadowTraining < ActiveRecord::Migration[7.1]
  def up
    execute "SET LOCAL lock_timeout = '4s'"
    execute "SET LOCAL statement_timeout = '5s'"
    create_runs
    create_candidates
    add_validated_foreign_keys
  end

  def down
    raise ActiveRecord::IrreversibleMigration, 'Retain AI history; rollback application source only.'
  end

  private

  def create_runs
    create_table :captain_shadow_training_runs do |t|
      t.references :account, null: false
      t.references :conversation, null: false
      t.references :assistant
      t.references :user, null: false
      t.references :inbound_message, null: false
      t.references :human_message, null: false
      t.string :status, null: false, default: 'queued'
      t.jsonb :snapshot, null: false, default: {}
      t.text :human_reply, null: false
      t.text :shadow_reply
      t.jsonb :comparison, null: false, default: {}
      t.string :error_code
      t.string :execution_token
      t.datetime :phase_started_at
      t.timestamps
    end
    add_index :captain_shadow_training_runs, [:account_id, :inbound_message_id], unique: true, name: 'idx_shadow_training_inbound_once'
  end

  def create_candidates
    create_table :captain_shadow_training_candidates do |t|
      t.references :account, null: false
      t.references :run, null: false
      t.string :kind, null: false
      t.string :status, null: false, default: 'pending'
      t.jsonb :proposal, null: false, default: {}
      t.timestamps
    end
    add_index :captain_shadow_training_candidates, [:run_id, :kind], unique: true, name: 'idx_shadow_training_candidate_once'
  end

  def add_validated_foreign_keys
    add_foreign_key :captain_shadow_training_runs, :accounts, column: :account_id, on_delete: :cascade, validate: false
    validate_foreign_key :captain_shadow_training_runs, :accounts, column: :account_id
    add_foreign_key :captain_shadow_training_runs, :conversations, column: :conversation_id, on_delete: :cascade, validate: false
    validate_foreign_key :captain_shadow_training_runs, :conversations, column: :conversation_id
    add_foreign_key :captain_shadow_training_runs, :captain_assistants, column: :assistant_id, on_delete: :cascade, validate: false
    validate_foreign_key :captain_shadow_training_runs, :captain_assistants, column: :assistant_id
    add_foreign_key :captain_shadow_training_runs, :users, column: :user_id, on_delete: :cascade, validate: false
    validate_foreign_key :captain_shadow_training_runs, :users, column: :user_id
    add_foreign_key :captain_shadow_training_runs, :messages, column: :inbound_message_id, on_delete: :cascade, validate: false
    validate_foreign_key :captain_shadow_training_runs, :messages, column: :inbound_message_id
    add_foreign_key :captain_shadow_training_runs, :messages, column: :human_message_id, on_delete: :cascade, validate: false
    validate_foreign_key :captain_shadow_training_runs, :messages, column: :human_message_id
    add_foreign_key :captain_shadow_training_candidates, :accounts, column: :account_id, on_delete: :cascade, validate: false
    validate_foreign_key :captain_shadow_training_candidates, :accounts, column: :account_id
    add_foreign_key :captain_shadow_training_candidates, :captain_shadow_training_runs, column: :run_id, on_delete: :cascade, validate: false
    validate_foreign_key :captain_shadow_training_candidates, :captain_shadow_training_runs, column: :run_id
  end
end
