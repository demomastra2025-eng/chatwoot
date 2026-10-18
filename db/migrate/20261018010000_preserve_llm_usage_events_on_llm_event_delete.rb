# frozen_string_literal: true

class PreserveLlmUsageEventsOnLlmEventDelete < ActiveRecord::Migration[7.1]
  def up
    change_column_null :llm_usage_events, :llm_event_id, true
    remove_foreign_key :llm_usage_events, :llm_events, if_exists: true
    add_foreign_key :llm_usage_events, :llm_events, on_delete: :nullify
  end

  def down
    remove_foreign_key :llm_usage_events, :llm_events, if_exists: true
    add_foreign_key :llm_usage_events, :llm_events, on_delete: :cascade
  end
end
