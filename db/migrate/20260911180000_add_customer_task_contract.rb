class AddCustomerTaskContract < ActiveRecord::Migration[7.0]
  def change
    add_reference :crm_task_types,
                  :customer_task_assignee,
                  foreign_key: { to_table: :users },
                  index: { name: 'idx_crm_task_types_customer_assignee' }
    add_reference :crm_task_types,
                  :customer_task_team,
                  foreign_key: { to_table: :teams },
                  index: { name: 'idx_crm_task_types_customer_team' }

    change_table :crm_tasks, bulk: true do |table|
      table.boolean :customer_visible, default: false, null: false
      table.string :customer_title
      table.text :customer_result
      table.text :customer_change_request
      table.datetime :customer_change_requested_at
      table.text :customer_cancellation_request
      table.datetime :customer_cancellation_requested_at
    end

    add_index :crm_tasks,
              [:account_id, :originating_conversation_id, :updated_at],
              name: 'idx_crm_tasks_customer_visible_conversation',
              where: 'customer_visible = TRUE'
  end
end
