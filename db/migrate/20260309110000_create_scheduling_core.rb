# frozen_string_literal: true

class CreateSchedulingCore < ActiveRecord::Migration[7.1]
  def change
    create_table :scheduling_resources do |t|
      t.references :account, null: false, foreign_key: true, index: true
      t.references :user, foreign_key: true, index: true
      t.string :name, null: false
      t.string :specialty
      t.string :photo_url
      t.text :description
      t.string :color
      t.string :timezone, null: false, default: 'Asia/Almaty'
      t.integer :slot_duration_min, null: false, default: 30
      t.string :compensation_type, null: false, default: 'percent'
      t.integer :compensation_value, null: false, default: 0
      t.boolean :active, null: false, default: true
      t.jsonb :custom_attributes, null: false, default: {}

      t.timestamps
    end

    add_index :scheduling_resources, [:account_id, :active, :name], name: 'idx_scheduling_resources_on_account_active_name'

    create_table :scheduling_work_rules do |t|
      t.references :account, null: false, foreign_key: true, index: true
      t.references :resource, null: false, foreign_key: { to_table: :scheduling_resources }, index: true
      t.integer :weekday, null: false
      t.integer :start_minute, null: false
      t.integer :end_minute, null: false
      t.boolean :active, null: false, default: true

      t.timestamps
    end

    add_index :scheduling_work_rules,
              [:account_id, :resource_id, :weekday, :active],
              name: 'idx_scheduling_work_rules_on_account_resource_weekday'
    add_index :scheduling_work_rules,
              [:resource_id, :weekday, :start_minute, :end_minute],
              unique: true,
              name: 'idx_scheduling_work_rules_on_resource_slot'

    create_table :scheduling_break_rules do |t|
      t.references :account, null: false, foreign_key: true, index: true
      t.references :resource, null: false, foreign_key: { to_table: :scheduling_resources }, index: true
      t.integer :weekday, null: false
      t.integer :start_minute, null: false
      t.integer :end_minute, null: false
      t.string :title
      t.boolean :active, null: false, default: true

      t.timestamps
    end

    add_index :scheduling_break_rules,
              [:account_id, :resource_id, :weekday, :active],
              name: 'idx_scheduling_break_rules_on_account_resource_weekday'
    add_index :scheduling_break_rules,
              [:resource_id, :weekday, :start_minute, :end_minute],
              unique: true,
              name: 'idx_scheduling_break_rules_on_resource_slot'

    create_table :scheduling_holidays do |t|
      t.references :account, null: false, foreign_key: true, index: true
      t.date :date, null: false
      t.string :title, null: false
      t.boolean :recurring_yearly, null: false, default: false
      t.boolean :working_day_override, null: false, default: false
      t.jsonb :custom_attributes, null: false, default: {}

      t.timestamps
    end

    add_index :scheduling_holidays, [:account_id, :date], name: 'idx_scheduling_holidays_on_account_date'

    create_table :scheduling_workday_overrides do |t|
      t.references :account, null: false, foreign_key: true, index: true
      t.references :resource, null: false, foreign_key: { to_table: :scheduling_resources }, index: true
      t.date :date, null: false
      t.integer :start_minute, null: false
      t.integer :end_minute, null: false
      t.integer :break_start_minute
      t.integer :break_end_minute
      t.string :break_title
      t.jsonb :custom_attributes, null: false, default: {}

      t.timestamps
    end

    add_index :scheduling_workday_overrides, [:resource_id, :date], unique: true, name: 'idx_scheduling_workday_overrides_on_resource_date'
    add_index :scheduling_workday_overrides, [:account_id, :date], name: 'idx_scheduling_workday_overrides_on_account_date'

    create_table :scheduling_time_offs do |t|
      t.references :account, null: false, foreign_key: true, index: true
      t.references :resource, foreign_key: { to_table: :scheduling_resources }, index: true
      t.string :kind, null: false
      t.datetime :starts_at, null: false
      t.datetime :ends_at, null: false
      t.string :title
      t.text :notes
      t.jsonb :custom_attributes, null: false, default: {}

      t.timestamps
    end

    add_index :scheduling_time_offs,
              [:account_id, :resource_id, :starts_at, :ends_at],
              name: 'idx_scheduling_time_offs_on_account_resource_range'

    create_table :scheduling_services do |t|
      t.references :account, null: false, foreign_key: true, index: true
      t.string :name, null: false
      t.integer :base_price, null: false, default: 0
      t.integer :duration_min, null: false, default: 30
      t.string :category
      t.string :direction
      t.string :service_type
      t.text :description
      t.boolean :active, null: false, default: true
      t.jsonb :custom_attributes, null: false, default: {}

      t.timestamps
    end

    add_index :scheduling_services, [:account_id, :active, :name], name: 'idx_scheduling_services_on_account_active_name'

    create_table :scheduling_service_prices do |t|
      t.references :account, null: false, foreign_key: true, index: true
      t.references :service, null: false, foreign_key: { to_table: :scheduling_services }, index: true
      t.references :resource, null: false, foreign_key: { to_table: :scheduling_resources }, index: true
      t.integer :price, null: false, default: 0
      t.string :compensation_type, null: false, default: 'percent'
      t.integer :compensation_value, null: false, default: 0
      t.boolean :active, null: false, default: true

      t.timestamps
    end

    add_index :scheduling_service_prices, [:service_id, :resource_id], unique: true, name: 'idx_scheduling_service_prices_on_service_resource'
    add_index :scheduling_service_prices,
              [:account_id, :resource_id, :active],
              name: 'idx_scheduling_service_prices_on_account_resource_active'

    create_table :scheduling_appointments do |t|
      t.references :account, null: false, foreign_key: true, index: true
      t.references :resource, null: false, foreign_key: { to_table: :scheduling_resources }, index: true
      t.references :contact, foreign_key: true, index: true
      t.references :service, foreign_key: { to_table: :scheduling_services }, index: true
      t.references :company, foreign_key: true, index: true
      t.references :conversation, foreign_key: true, index: true
      t.references :created_by, foreign_key: { to_table: :users }, index: true
      t.string :service_name_snapshot
      t.string :service_type_snapshot
      t.integer :service_duration_min_snapshot
      t.datetime :starts_at, null: false
      t.datetime :ends_at, null: false
      t.integer :duration_min, null: false, default: 30
      t.string :status, null: false, default: 'scheduled'
      t.string :appointment_type, null: false, default: 'primary'
      t.string :client_name, null: false
      t.string :client_phone
      t.string :client_identifier
      t.date :client_birth_date
      t.string :client_gender
      t.text :client_comment
      t.string :source, null: false, default: 'manual'
      t.string :external_ref
      t.string :idempotency_key
      t.integer :service_amount, null: false, default: 0
      t.string :compensation_type_snapshot
      t.integer :compensation_value_snapshot
      t.integer :prepaid_amount, null: false, default: 0
      t.string :prepaid_payment_method
      t.integer :settlement_amount, null: false, default: 0
      t.string :settlement_payment_method
      t.string :payment_status, null: false, default: 'awaiting_payment'
      t.jsonb :custom_attributes, null: false, default: {}

      t.timestamps
    end

    add_index :scheduling_appointments,
              [:account_id, :resource_id, :starts_at, :ends_at],
              name: 'idx_scheduling_appointments_on_account_resource_range'
    add_index :scheduling_appointments, [:account_id, :starts_at], name: 'idx_scheduling_appointments_on_account_starts_at'
    add_index :scheduling_appointments,
              [:account_id, :external_ref],
              unique: true,
              where: 'external_ref IS NOT NULL',
              name: 'idx_scheduling_appointments_on_account_external_ref'
    add_index :scheduling_appointments,
              [:account_id, :idempotency_key],
              unique: true,
              where: 'idempotency_key IS NOT NULL',
              name: 'idx_scheduling_appointments_on_account_idempotency_key'

    create_table :scheduling_payments do |t|
      t.references :account, null: false, foreign_key: true, index: true
      t.references :appointment, null: false, foreign_key: { to_table: :scheduling_appointments }, index: true
      t.references :recorded_by, foreign_key: { to_table: :users }, index: true
      t.integer :amount, null: false, default: 0
      t.string :payment_method, null: false
      t.string :payment_kind, null: false, default: 'payment'

      t.timestamps
    end

    add_index :scheduling_payments,
              [:appointment_id, :payment_kind],
              unique: true,
              where: "payment_kind = 'prepaid'",
              name: 'idx_scheduling_payments_on_appointment_prepaid'
    add_index :scheduling_payments,
              [:appointment_id, :payment_kind],
              unique: true,
              where: "payment_kind = 'adjustment'",
              name: 'idx_scheduling_payments_on_appointment_adjustment'
    add_index :scheduling_payments,
              [:account_id, :created_at],
              name: 'idx_scheduling_payments_on_account_created_at'

    create_table :scheduling_expenses do |t|
      t.references :account, null: false, foreign_key: true, index: true
      t.references :appointment, null: false, foreign_key: { to_table: :scheduling_appointments }, index: { unique: true }
      t.references :resource, null: false, foreign_key: { to_table: :scheduling_resources }, index: true
      t.references :paid_by, foreign_key: { to_table: :users }, index: true
      t.integer :amount, null: false, default: 0
      t.string :status, null: false, default: 'unpaid'
      t.datetime :paid_at

      t.timestamps
    end

    add_index :scheduling_expenses, [:account_id, :status], name: 'idx_scheduling_expenses_on_account_status'
  end
end
