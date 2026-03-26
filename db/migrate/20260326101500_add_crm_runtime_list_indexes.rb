class AddCrmRuntimeListIndexes < ActiveRecord::Migration[7.0]
  disable_ddl_transaction!

  TASKS_INDEX_NAME = 'index_crm_tasks_on_active_ordering'.freeze
  DEALS_INDEX_NAME = 'index_crm_deals_on_active_ordering'.freeze

  def up
    add_index :crm_tasks,
              [:account_id, :due_at, :updated_at, :id],
              name: TASKS_INDEX_NAME,
              where: 'archived_at IS NULL',
              order: { due_at: :asc, updated_at: :desc, id: :desc },
              algorithm: :concurrently

    add_index :crm_deals,
              [:account_id, :expected_close_on, :updated_at, :id],
              name: DEALS_INDEX_NAME,
              where: 'archived_at IS NULL',
              order: { expected_close_on: :asc, updated_at: :desc, id: :desc },
              algorithm: :concurrently
  end

  def down
    remove_index :crm_tasks, name: TASKS_INDEX_NAME, algorithm: :concurrently, if_exists: true
    remove_index :crm_deals, name: DEALS_INDEX_NAME, algorithm: :concurrently, if_exists: true
  end
end
