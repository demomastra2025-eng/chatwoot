class AddColorToCrmTaskStatuses < ActiveRecord::Migration[7.0]
  class MigrationCrmTaskStatus < ApplicationRecord
    self.table_name = 'crm_task_statuses'
  end

  TASK_STATUS_STANDARD_COLORS = [
    '#F0F0F3',
    '#E8E8EC',
    '#0EA5E9',
    '#3B82F6',
    '#6366F1',
    '#8B5CF6',
    '#A855F7',
    '#EC4899',
    '#F97316',
    '#EAB308',
    '#22C55E',
    '#14B8A6',
  ].freeze

  def up
    add_column :crm_task_statuses, :color, :string, null: false, default: TASK_STATUS_STANDARD_COLORS.first

    say_with_time 'Backfilling CRM task status colors per account' do
      MigrationCrmTaskStatus.reset_column_information

      MigrationCrmTaskStatus.order(:account_id, :position, :id).group_by(&:account_id).each_value do |task_statuses|
        task_statuses.each_with_index do |task_status, index|
          task_status.update_columns(color: TASK_STATUS_STANDARD_COLORS[index] || TASK_STATUS_STANDARD_COLORS.first)
        end
      end
    end
  end

  def down
    remove_column :crm_task_statuses, :color
  end
end
