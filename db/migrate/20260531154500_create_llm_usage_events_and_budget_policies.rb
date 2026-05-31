# frozen_string_literal: true

class CreateLlmUsageEventsAndBudgetPolicies < ActiveRecord::Migration[7.1]
  def change
    create_llm_usage_events
    create_llm_budget_policies
  end

  private

  def create_llm_usage_events
    create_table :llm_usage_events do |t|
      t.integer :account_id
      t.references :llm_event, null: false, index: { unique: true }
      t.datetime :occurred_at, null: false
      t.string :event_name, null: false
      t.string :feature
      t.string :provider
      t.string :actual_provider
      t.string :requested_model
      t.string :actual_model
      t.string :routing_profile
      t.string :status
      t.string :error_code
      t.integer :prompt_tokens
      t.integer :completion_tokens
      t.integer :reasoning_tokens
      t.integer :cached_tokens
      t.integer :total_tokens
      t.decimal :estimated_cost, precision: 14, scale: 8
      t.integer :duration_ms
      t.string :generation_id
      t.string :trace_id
      t.string :session_id
      t.string :request_id
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    add_foreign_key :llm_usage_events, :llm_events, on_delete: :cascade
    add_index :llm_usage_events, [:account_id, :occurred_at], name: 'idx_llm_usage_events_account_occurred'
    add_index :llm_usage_events, [:account_id, :feature, :occurred_at], name: 'idx_llm_usage_events_account_feature_occurred'
    add_index :llm_usage_events, [:provider, :occurred_at], name: 'idx_llm_usage_events_provider_occurred'
    add_index :llm_usage_events, [:account_id, :generation_id], name: 'idx_llm_usage_events_account_generation', where: 'generation_id IS NOT NULL'
  end

  def create_llm_budget_policies
    create_table :llm_budget_policies do |t|
      t.integer :account_id
      t.string :scope_type, null: false, default: 'account'
      t.string :feature
      t.boolean :active, null: false, default: true
      t.boolean :hard_stop, null: false, default: false
      t.decimal :daily_budget, precision: 14, scale: 8
      t.decimal :monthly_budget, precision: 14, scale: 8
      t.decimal :warning_threshold, precision: 5, scale: 4, default: 0.8
      t.string :fallback_profile
      t.jsonb :per_feature_caps, null: false, default: {}
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    add_index :llm_budget_policies, [:account_id, :feature, :active], name: 'idx_llm_budget_policies_account_feature_active'
    add_index :llm_budget_policies, [:scope_type, :active], name: 'idx_llm_budget_policies_scope_active'
  end
end
