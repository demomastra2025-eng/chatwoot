# frozen_string_literal: true

class AddRcaFieldsToLlmEvents < ActiveRecord::Migration[7.1]
  def change
    add_column :llm_events, :project_case_id, :string unless column_exists?(:llm_events, :project_case_id)
    add_column :llm_events, :error_code, :string unless column_exists?(:llm_events, :error_code)
    add_column :llm_events, :queue_wait_ms, :integer unless column_exists?(:llm_events, :queue_wait_ms)
    add_column :llm_events, :thinking_tokens, :integer unless column_exists?(:llm_events, :thinking_tokens)
    add_column :llm_events, :payload_bytes, :integer unless column_exists?(:llm_events, :payload_bytes)
    add_column :llm_events, :payload_truncated, :boolean, default: false, null: false unless column_exists?(:llm_events, :payload_truncated)
    add_column :llm_events, :retry_count, :integer unless column_exists?(:llm_events, :retry_count)
    add_column :llm_events, :tool_calls_count, :integer unless column_exists?(:llm_events, :tool_calls_count)
    add_column :llm_events, :schema_invalid_count, :integer unless column_exists?(:llm_events, :schema_invalid_count)

    add_index :llm_events,
              [:account_id, :project_case_id, :created_at],
              name: 'index_llm_events_on_account_project_case_created_at',
              where: 'project_case_id IS NOT NULL',
              if_not_exists: true
    add_index :llm_events,
              [:account_id, :error_code, :created_at],
              name: 'index_llm_events_on_account_error_code_created_at',
              where: 'error_code IS NOT NULL',
              if_not_exists: true
  end
end
