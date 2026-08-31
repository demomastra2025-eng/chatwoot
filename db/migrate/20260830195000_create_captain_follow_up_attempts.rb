class CreateCaptainFollowUpAttempts < ActiveRecord::Migration[7.1]
  def change
    create_table :captain_follow_up_attempts do |t|
      t.references :account, null: false, foreign_key: { on_delete: :cascade }
      t.references :assistant, null: false, foreign_key: { to_table: :captain_assistants, on_delete: :cascade }
      t.references :conversation, null: false, foreign_key: { on_delete: :cascade }
      t.references :anchor_message, null: false, foreign_key: { to_table: :messages, on_delete: :cascade }
      t.integer :step_index, null: false
      t.string :attempt_key, null: false, limit: 64
      t.text :generated_content
      t.string :status, null: false, default: 'processing'
      t.datetime :processing_started_at, null: false
      t.datetime :generated_at
      t.datetime :completed_at
      t.datetime :expires_at, null: false

      t.timestamps
    end

    add_index :captain_follow_up_attempts, :attempt_key, unique: true
    add_index :captain_follow_up_attempts,
              [:anchor_message_id, :created_at],
              name: 'index_captain_follow_up_attempts_on_anchor_and_created_at'
    add_index :captain_follow_up_attempts,
              [:status, :expires_at],
              name: 'index_captain_follow_up_attempts_on_status_and_expires_at'
  end
end
