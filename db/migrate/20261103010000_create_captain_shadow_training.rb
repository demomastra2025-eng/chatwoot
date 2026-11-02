class CreateCaptainShadowTraining < ActiveRecord::Migration[7.1]
  def change
    create_runs
    create_candidates
  end

  private

  def create_runs
    create_table :captain_shadow_training_runs do |t|
      t.references :account, null: false, foreign_key: { on_delete: :cascade }
      t.references :conversation, null: false, foreign_key: { on_delete: :cascade }
      t.references :assistant, foreign_key: { to_table: :captain_assistants, on_delete: :cascade }
      t.references :user, null: false, foreign_key: { on_delete: :cascade }
      t.references :inbound_message, null: false, foreign_key: { to_table: :messages, on_delete: :cascade }
      t.references :human_message, null: false, foreign_key: { to_table: :messages, on_delete: :cascade }
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
      t.references :account, null: false, foreign_key: { on_delete: :cascade }
      t.references :run, null: false, foreign_key: { to_table: :captain_shadow_training_runs, on_delete: :cascade }
      t.string :kind, null: false
      t.string :status, null: false, default: 'pending'
      t.jsonb :proposal, null: false, default: {}
      t.timestamps
    end
    add_index :captain_shadow_training_candidates, [:run_id, :kind], unique: true, name: 'idx_shadow_training_candidate_once'
  end
end
