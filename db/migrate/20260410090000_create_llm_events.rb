class CreateLlmEvents < ActiveRecord::Migration[7.1]
  def change
    create_llm_events_table
    add_llm_events_indexes
  end

  private

  def create_llm_events_table
    create_table :llm_events do |t|
      t.integer :account_id
      t.bigint :assistant_id
      t.bigint :conversation_id
      t.integer :conversation_display_id
      t.bigint :copilot_thread_id

      t.string :event_name, null: false
      t.string :feature
      t.string :runtime_mode
      t.string :status
      t.string :reason
      t.string :provider
      t.string :model
      t.string :tool_name
      t.string :schema_name
      t.string :current_agent
      t.string :channel_type
      t.string :source
      t.string :session_id

      t.integer :prompt_tokens
      t.integer :completion_tokens
      t.integer :total_tokens
      t.integer :duration_ms
      t.integer :credit_multiplier
      t.decimal :estimated_cost, precision: 12, scale: 8

      t.boolean :blocked, null: false, default: false
      t.boolean :moderation_skipped, null: false, default: false
      t.boolean :schema_invalid, null: false, default: false
      t.boolean :tool_failure, null: false, default: false
      t.boolean :error, null: false, default: false

      t.jsonb :payload, null: false, default: {}

      t.timestamps
    end
  end

  def add_llm_events_indexes
    add_index :llm_events, [:event_name, :created_at], name: 'index_llm_events_on_event_name_created_at'
    add_index :llm_events, [:account_id, :created_at], name: 'index_llm_events_on_account_created_at'
    add_index :llm_events, [:account_id, :feature, :created_at], name: 'index_llm_events_on_account_feature_created_at'
    add_index :llm_events, [:account_id, :model, :created_at], name: 'index_llm_events_on_account_model_created_at'
    add_index :llm_events, [:assistant_id, :created_at], name: 'index_llm_events_on_assistant_created_at'
    add_index :llm_events, [:conversation_id, :created_at], name: 'index_llm_events_on_conversation_created_at'
  end
end
