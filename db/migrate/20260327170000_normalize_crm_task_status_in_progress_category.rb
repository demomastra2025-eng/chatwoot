class NormalizeCrmTaskStatusInProgressCategory < ActiveRecord::Migration[7.1]
  def up
    execute <<~SQL.squish
      UPDATE crm_task_statuses
      SET category = 'in_progress', updated_at = CURRENT_TIMESTAMP
      WHERE code = 'in_progress' AND category = 'open'
    SQL
  end

  def down
    execute <<~SQL.squish
      UPDATE crm_task_statuses
      SET category = 'open', updated_at = CURRENT_TIMESTAMP
      WHERE code = 'in_progress' AND category = 'in_progress'
    SQL
  end
end
