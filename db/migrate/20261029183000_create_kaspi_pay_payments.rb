# frozen_string_literal: true

class CreateKaspiPayPayments < ActiveRecord::Migration[7.1]
  LEGACY_TOMBSTONE_CONSTRAINT = 'integrations_hooks_app_id_not_retired_payment_provider'

  def up
    if check_constraint_exists?(:integrations_hooks, name: LEGACY_TOMBSTONE_CONSTRAINT)
      remove_check_constraint :integrations_hooks, name: LEGACY_TOMBSTONE_CONSTRAINT
    end

    create_table :kaspi_pay_payments do |t|
      add_reference_columns(t)
      add_payment_columns(t)
      add_tracking_columns(t)
      t.timestamps
    end

    add_payment_indexes
  end

  def down
    drop_table :kaspi_pay_payments, if_exists: true
    execute("DELETE FROM integrations_hooks WHERE app_id = 'kaspi_pay'")
    return if check_constraint_exists?(:integrations_hooks, name: LEGACY_TOMBSTONE_CONSTRAINT)

    add_check_constraint :integrations_hooks, "app_id <> 'kaspi_pay'", name: LEGACY_TOMBSTONE_CONSTRAINT
  end

  private

  def add_reference_columns(table)
    table.references :account, null: false, foreign_key: true
    table.references :hook, foreign_key: { to_table: :integrations_hooks, on_delete: :nullify }
    table.references :contact, foreign_key: { on_delete: :nullify }
    table.references :conversation, foreign_key: { on_delete: :nullify }
    table.references :appointment, foreign_key: { to_table: :scheduling_appointments, on_delete: :nullify }
    table.references :crm_deal, foreign_key: { to_table: :crm_deals, on_delete: :nullify }
    table.references :created_by, foreign_key: { to_table: :users, on_delete: :nullify }
  end

  def add_payment_columns(table)
    table.string :payment_type, null: false
    table.string :status, null: false, default: 'pending'
    table.string :provider_status
    table.text :provider_status_desc
    table.string :qr_operation_id, null: false
    table.string :order_number
    table.integer :amount, null: false
    table.integer :refunded_amount, null: false, default: 0
    table.string :payer_phone_masked
    table.text :comment
    table.text :pay_url
    table.text :unified_qr_url
    table.text :receipt_url
  end

  def add_tracking_columns(table)
    table.datetime :expires_at
    table.datetime :paid_at
    table.integer :poll_attempts, null: false, default: 0
    table.datetime :last_polled_at
    table.jsonb :metadata, null: false, default: {}
  end

  def add_payment_indexes
    add_index :kaspi_pay_payments, [:account_id, :qr_operation_id], unique: true, name: 'idx_kaspi_pay_payments_on_account_and_op_id'
    add_index :kaspi_pay_payments, [:account_id, :status], name: 'idx_kaspi_pay_payments_on_account_and_status'
    add_index :kaspi_pay_payments, [:account_id, :created_at], name: 'idx_kaspi_pay_payments_on_account_and_created_at'
  end
end
