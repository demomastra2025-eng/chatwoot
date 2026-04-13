class AddPositionToCrmBoardCards < ActiveRecord::Migration[7.0]
  class MigrationCrmDeal < ApplicationRecord
    self.table_name = 'crm_deals'
  end

  class MigrationCrmTask < ApplicationRecord
    self.table_name = 'crm_tasks'
  end

  def up
    add_column :crm_deals, :position, :integer, null: false, default: 0
    add_column :crm_tasks, :position, :integer, null: false, default: 0

    add_index :crm_deals, [:account_id, :stage_id, :position, :id], name: 'index_crm_deals_on_account_stage_position'
    add_index :crm_tasks, [:account_id, :status_id, :position, :id], name: 'index_crm_tasks_on_account_status_position'

    say_with_time 'Backfilling CRM deal positions' do
      backfill_positions(
        MigrationCrmDeal,
        group_columns: [:account_id, :stage_id],
        order_clause: {
          account_id: :asc,
          stage_id: :asc,
          expected_close_on: :asc,
          updated_at: :desc,
          id: :desc,
        }
      )
    end

    say_with_time 'Backfilling CRM task positions' do
      backfill_positions(
        MigrationCrmTask,
        group_columns: [:account_id, :status_id],
        order_clause: {
          account_id: :asc,
          status_id: :asc,
          due_at: :asc,
          updated_at: :desc,
          id: :desc,
        }
      )
    end
  end

  def down
    remove_index :crm_tasks, name: 'index_crm_tasks_on_account_status_position'
    remove_index :crm_deals, name: 'index_crm_deals_on_account_stage_position'

    remove_column :crm_tasks, :position
    remove_column :crm_deals, :position
  end

  private

  def backfill_positions(model_class, group_columns:, order_clause:)
    current_group = nil
    position = 0

    model_class.order(order_clause).each do |record|
      record_group = group_columns.map { |column| record.public_send(column) }

      if record_group != current_group
        current_group = record_group
        position = 0
      end

      position += 1
      record.update_columns(position: position)
    end
  end
end
