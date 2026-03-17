class AddCompensationPercentToScheduling < ActiveRecord::Migration[7.0]
  def change
    add_column :scheduling_resources, :compensation_percent, :integer, default: 0, null: false
    add_column :scheduling_service_prices, :compensation_percent, :integer, default: 0, null: false
    add_column :scheduling_appointments, :compensation_percent_snapshot, :integer, default: 0, null: false
  end
end
