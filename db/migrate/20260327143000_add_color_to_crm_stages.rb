class AddColorToCrmStages < ActiveRecord::Migration[7.0]
  class MigrationCrmStage < ApplicationRecord
    self.table_name = 'crm_stages'
  end

  STAGE_STANDARD_COLORS = [
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
    add_column :crm_stages, :color, :string, null: false, default: STAGE_STANDARD_COLORS.first

    say_with_time 'Backfilling CRM stage colors per pipeline' do
      MigrationCrmStage.reset_column_information

      MigrationCrmStage.order(:pipeline_id, :position, :id).group_by(&:pipeline_id).each_value do |stages|
        stages.each_with_index do |stage, index|
          stage.update_columns(color: STAGE_STANDARD_COLORS[index] || STAGE_STANDARD_COLORS.first)
        end
      end
    end
  end

  def down
    remove_column :crm_stages, :color
  end
end
