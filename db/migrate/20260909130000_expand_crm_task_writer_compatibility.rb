class ExpandCrmTaskWriterCompatibility < ActiveRecord::Migration[7.1]
  def up
    # Reconcile environments where an earlier version of the catalog/context
    # migrations was already applied with NOT NULL constraints.
    change_column_null :crm_tasks, :task_type_id, true if column_exists?(:crm_tasks, :task_type_id)
    change_column_null :crm_tasks, :context_kind, true if column_exists?(:crm_tasks, :context_kind)
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
          'Restore NOT NULL only after every CRM task writer is upgraded and null rows are backfilled'
  end
end
