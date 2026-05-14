class CreateKaspiPayPayments < ActiveRecord::Migration[7.0]
  def change
    create_table :kaspi_pay_payments do |t|
      t.references :account, null: false, foreign_key: true
      t.references :integration_hook, null: false, foreign_key: { to_table: :integrations_hooks }
      t.references :source, polymorphic: true, null: true
      t.string :payment_type, null: false
      t.integer :amount, null: false
      t.string :currency, null: false, default: 'KZT'
      t.string :kaspi_operation_id
      t.string :kaspi_order_number
      t.string :status, null: false, default: 'pending'
      t.string :status_description
      t.text :qr_token
      t.string :receipt_url
      t.datetime :expires_at
      t.datetime :paid_at
      t.datetime :failed_at
      t.string :idempotency_key
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    add_index :kaspi_pay_payments, [:account_id, :kaspi_operation_id], unique: true, where: 'kaspi_operation_id IS NOT NULL'
    add_index :kaspi_pay_payments, [:account_id, :idempotency_key], unique: true, where: 'idempotency_key IS NOT NULL'
    add_index :kaspi_pay_payments, [:account_id, :status]
  end
end
