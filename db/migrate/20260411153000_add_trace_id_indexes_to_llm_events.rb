class AddTraceIdIndexesToLlmEvents < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  def up
    add_column :llm_events, :trace_id, :string unless column_exists?(:llm_events, :trace_id)

    unless index_exists?(:llm_events, [:account_id, :trace_id, :created_at], name: 'index_llm_events_on_account_trace_created_at')
      add_index :llm_events,
                [:account_id, :trace_id, :created_at],
                name: 'index_llm_events_on_account_trace_created_at',
                where: 'trace_id IS NOT NULL',
                algorithm: :concurrently
    end

    unless index_exists?(:llm_events, [:account_id, :session_id, :created_at], name: 'index_llm_events_on_account_session_created_at')
      add_index :llm_events,
                [:account_id, :session_id, :created_at],
                name: 'index_llm_events_on_account_session_created_at',
                where: 'session_id IS NOT NULL',
                algorithm: :concurrently
    end
  end

  def down
    remove_index :llm_events, name: 'index_llm_events_on_account_trace_created_at' if index_exists?(:llm_events, name: 'index_llm_events_on_account_trace_created_at')
    remove_index :llm_events, name: 'index_llm_events_on_account_session_created_at' if index_exists?(:llm_events, name: 'index_llm_events_on_account_session_created_at')
    remove_column :llm_events, :trace_id if column_exists?(:llm_events, :trace_id)
  end
end
