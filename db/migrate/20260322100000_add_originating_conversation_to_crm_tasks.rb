class AddOriginatingConversationToCrmTasks < ActiveRecord::Migration[7.0]
  def change
    add_reference :crm_tasks,
                  :originating_conversation,
                  foreign_key: { to_table: :conversations }

    add_index :crm_tasks,
              [:account_id, :originating_conversation_id],
              name: 'index_crm_tasks_on_account_originating_conversation'
  end
end
