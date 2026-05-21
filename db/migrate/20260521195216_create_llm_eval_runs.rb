class CreateLlmEvalRuns < ActiveRecord::Migration[7.0]
  def change
    create_table :llm_eval_runs do |t|
      t.references :account, null: false, foreign_key: true, index: true
      t.references :user, foreign_key: true, index: true
      t.string :status, null: false, default: 'queued'
      t.string :mode, null: false, default: 'live_model'
      t.jsonb :pack_ids, null: false, default: []
      t.integer :requested_budget_cents, null: false, default: 0
      t.integer :max_cases
      t.jsonb :result, null: false, default: {}
      t.jsonb :metadata, null: false, default: {}
      t.text :error_message
      t.datetime :started_at
      t.datetime :finished_at

      t.timestamps
    end

    add_index :llm_eval_runs, [:account_id, :created_at]
    add_index :llm_eval_runs, [:account_id, :status]
  end
end
