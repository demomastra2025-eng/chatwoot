# frozen_string_literal: true

class AddRequestIdToLlmEvents < ActiveRecord::Migration[7.0]
  disable_ddl_transaction!

  def change
    add_column :llm_events, :request_id, :string

    add_index :llm_events,
              [:account_id, :request_id, :created_at],
              where: 'request_id IS NOT NULL',
              algorithm: :concurrently,
              name: 'index_llm_events_on_account_request_created_at'
  end
end
