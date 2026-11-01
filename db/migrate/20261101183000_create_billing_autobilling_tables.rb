# frozen_string_literal: true

class CreateBillingAutobillingTables < ActiveRecord::Migration[7.1]
  def up
    create_account_profiles_table
    create_invoices_table
    create_payment_events_table
  end

  def down
    drop_table :billing_payment_events, if_exists: true
    drop_table :billing_invoices, if_exists: true
    drop_table :billing_account_profiles, if_exists: true
  end

  private

  def create_account_profiles_table
    create_table :billing_account_profiles do |t|
      t.references :account, null: false, foreign_key: true, index: { unique: true }
      add_profile_subscription_columns(t)
      add_profile_payment_columns(t)
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end
    add_index :billing_account_profiles, :billing_tax_id
    add_index :billing_account_profiles, %i[billing_enabled paid_until], name: 'idx_billing_account_profiles_enabled_paid_until'
  end

  def add_profile_subscription_columns(table)
    table.boolean :billing_enabled, null: false, default: false
    table.date :paid_until
    table.integer :billing_day
    table.string :billing_tax_id
    table.string :legal_name
    table.string :contract_number
    table.date :contract_signed_on
    table.bigint :custom_monthly_price_minor
    table.boolean :annual_discount, null: false, default: false
    table.integer :extra_seats_count, null: false, default: 0
    table.integer :extra_storage_packs_count, null: false, default: 0
    table.string :knp_code, null: false, default: '859'
  end

  def add_profile_payment_columns(table)
    table.string :billing_email
    table.bigint :billing_whatsapp_conversation_id
    table.boolean :autopay_enabled, null: false, default: false
    table.string :bcc_card_token
    table.string :bcc_card_masked
    table.boolean :payment_overdue_banner, null: false, default: false
    table.string :overdue_invoice_number
    table.integer :partner_commission_rate_pct, null: false, default: 0
  end

  def create_invoices_table
    create_table :billing_invoices do |t|
      t.references :account, null: false, foreign_key: true
      add_invoice_core_columns(t)
      add_invoice_amount_columns(t)
      add_invoice_settlement_columns(t)
      add_invoice_closing_doc_columns(t)
      t.timestamps
    end
    add_invoice_indexes
  end

  def add_invoice_core_columns(table)
    table.string :invoice_number, null: false
    table.string :status, null: false, default: 'issued'
    table.date :period_start, null: false
    table.date :period_end, null: false
    table.string :usage_period_month
    table.date :due_on, null: false
    table.string :currency, null: false, default: 'KZT'
    table.string :plan_key
    table.string :payer_tax_id
    table.string :payer_legal_name
    table.string :knp_code, null: false, default: '859'
    table.string :payment_purpose, null: false
  end

  def add_invoice_amount_columns(table)
    table.bigint :base_amount_minor, null: false, default: 0
    table.bigint :addons_amount_minor, null: false, default: 0
    table.integer :ai_dialogs_overage_count, null: false, default: 0
    table.bigint :ai_dialogs_overage_minor, null: false, default: 0
    table.integer :call_minutes_overage_count, null: false, default: 0
    table.bigint :call_minutes_overage_minor, null: false, default: 0
    table.bigint :amount_minor, null: false
    table.bigint :partner_commission_base_minor, null: false, default: 0
  end

  def add_invoice_settlement_columns(table)
    table.string :bcc_external_invoice_id
    table.string :payment_url
    table.datetime :paid_at
    table.string :bank_reference_id
    table.integer :recurring_attempts_count, null: false, default: 0
    table.datetime :last_recurring_attempt_at
    table.string :last_reminder_stage
  end

  def add_invoice_closing_doc_columns(table)
    table.string :edo_document_id
    table.string :edo_status
    table.datetime :signed_by_counterparty_at
    table.string :esf_id
    table.string :esf_status
    table.jsonb :line_items, null: false, default: []
    table.jsonb :metadata, null: false, default: {}
  end

  def add_invoice_indexes
    add_index :billing_invoices, :invoice_number, unique: true
    add_index :billing_invoices, %i[account_id period_start],
              unique: true,
              where: "status <> 'cancelled'",
              name: 'idx_billing_invoices_unique_active_period'
    add_index :billing_invoices, %i[status due_on]
  end

  def create_payment_events_table
    create_table :billing_payment_events do |t|
      t.string :bank_reference_id, null: false
      t.string :source, null: false
      t.string :status, null: false
      t.references :billing_invoice, foreign_key: { to_table: :billing_invoices, on_delete: :nullify }
      t.references :account, foreign_key: { on_delete: :nullify }
      add_payment_event_detail_columns(t)
      t.timestamps
    end
    add_index :billing_payment_events, %i[source bank_reference_id], unique: true, name: 'idx_billing_payment_events_source_ref'
    add_index :billing_payment_events, :status
  end

  def add_payment_event_detail_columns(table)
    table.bigint :amount_minor, null: false
    table.string :currency, null: false, default: 'KZT'
    table.string :sender_tax_id
    table.string :sender_name
    table.string :payment_purpose
    table.datetime :occurred_at
    table.string :review_reason
    table.jsonb :metadata, null: false, default: {}
    table.jsonb :raw_payload, null: false, default: {}
  end
end
