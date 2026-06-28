class AddActivityTypeAndOutcomeToCrmTasks < ActiveRecord::Migration[7.0]
  disable_ddl_transaction!

  def up
    add_column :crm_tasks, :activity_type, :string, null: false, default: 'task'
    add_column :crm_tasks, :outcome, :string

    add_index :crm_tasks,
              [:account_id, :activity_type, :due_at],
              name: 'index_crm_tasks_on_account_activity_type_due_at',
              algorithm: :concurrently
    add_index :crm_tasks,
              [:account_id, :deal_id, :activity_type],
              name: 'index_crm_tasks_on_account_deal_activity_type',
              algorithm: :concurrently
  end

  def down
    if index_exists?(:crm_tasks, name: 'index_crm_tasks_on_account_deal_activity_type')
      remove_index :crm_tasks,
                   name: 'index_crm_tasks_on_account_deal_activity_type',
                   algorithm: :concurrently
    end

    if index_exists?(:crm_tasks, name: 'index_crm_tasks_on_account_activity_type_due_at')
      remove_index :crm_tasks,
                   name: 'index_crm_tasks_on_account_activity_type_due_at',
                   algorithm: :concurrently
    end

    remove_column :crm_tasks, :outcome if column_exists?(:crm_tasks, :outcome)
    remove_column :crm_tasks, :activity_type if column_exists?(:crm_tasks, :activity_type)
  end
end
