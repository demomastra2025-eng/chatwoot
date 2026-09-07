class EnforcePositiveCrmTaskPositions < ActiveRecord::Migration[7.1]
  def up
    execute <<~SQL.squish
      UPDATE crm_tasks
      SET position = 1
      WHERE position < 1
    SQL
    change_column_default :crm_tasks, :position, from: 0, to: 1
  end

  def down
    change_column_default :crm_tasks, :position, from: 1, to: 0
  end
end