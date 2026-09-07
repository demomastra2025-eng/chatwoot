class AddLifecycleFieldsToCrmTasks < ActiveRecord::Migration[7.1]
  def change
    change_table :crm_tasks, bulk: true do |table|
      table.references :completed_by, foreign_key: { to_table: :users, on_delete: :nullify }
      table.datetime :cancelled_at
      table.references :cancelled_by, foreign_key: { to_table: :users, on_delete: :nullify }
      table.text :cancellation_reason
      table.integer :reschedule_count, null: false, default: 0
    end

    add_check_constraint :crm_tasks,
                         'reschedule_count >= 0',
                         name: 'crm_tasks_reschedule_count_non_negative'
    add_check_constraint :crm_tasks,
                         <<~SQL.squish,
                           (cancelled_at IS NULL AND cancellation_reason IS NULL) OR
                           (cancelled_at IS NOT NULL AND LENGTH(BTRIM(cancellation_reason)) > 0)
                         SQL
                         name: 'crm_tasks_cancellation_state_complete'
  end
end
