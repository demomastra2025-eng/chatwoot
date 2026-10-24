# frozen_string_literal: true

# Which service a specialist really performs and how long the visit really lasts, read from the visit history (imported
# MedElement receptions carry the service codes after the visit). MedElement gives no specialist-to-service relation through its API.
class CreateSchedulingResourceServiceStats < ActiveRecord::Migration[7.1]
  def change
    create_table :scheduling_resource_service_stats do |t|
      t.references :account, null: false, foreign_key: true
      t.references :resource, null: false, foreign_key: { to_table: :scheduling_resources }, index: false
      t.references :service, null: false, foreign_key: { to_table: :scheduling_services }, index: false
      t.integer :receptions_count, null: false, default: 0
      t.datetime :last_seen_at
      t.integer :median_duration_min
      t.string :source, null: false, default: 'history'
      t.string :status, null: false, default: 'auto'
      t.timestamps
    end

    add_index :scheduling_resource_service_stats, %i[resource_id service_id], unique: true,
                                                                              name: 'idx_scheduling_resource_service_stats_on_resource_service'
    add_index :scheduling_resource_service_stats, %i[service_id status],
              name: 'idx_scheduling_resource_service_stats_on_service_status'
  end
end
