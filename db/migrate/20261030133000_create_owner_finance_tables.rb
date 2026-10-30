# frozen_string_literal: true

class CreateOwnerFinanceTables < ActiveRecord::Migration[7.1]
  def change
    create_accounts_table
    create_counterparties_table
    create_contracts_table
    create_deadlines_table
    create_transactions_table
    create_tombstones_table
    create_obligations_table
    create_sync_states_table
  end

  private

  def create_accounts_table
    create_table :owner_finance_accounts do |t|
      t.string :name, null: false
      t.string :account_kind, null: false, default: 'business_bank'
      t.string :bank_code, :external_source_key
      t.string :currency, null: false, default: 'KZT'
      t.decimal :current_balance, precision: 15, scale: 2, null: false, default: 0
      t.string :scope, null: false, default: 'business'
      t.boolean :active, null: false, default: true
      t.text :notes
      t.timestamps
    end
    add_index :owner_finance_accounts, :external_source_key, unique: true, where: 'external_source_key IS NOT NULL'
  end

  def create_counterparties_table
    create_table :owner_finance_counterparties do |t|
      t.string :display_name, :normalized_key, null: false
      t.string :kind, null: false, default: 'vendor'
      t.string :bin_iin, :default_category, :default_pnl_treatment, :external_source_key
      t.text :notes
      t.timestamps
    end
    add_index :owner_finance_counterparties, :normalized_key, unique: true
    add_index :owner_finance_counterparties, :external_source_key, unique: true, where: 'external_source_key IS NOT NULL'
  end

  def create_contracts_table
    create_table :owner_finance_contracts do |t|
      t.references :counterparty, foreign_key: { to_table: :owner_finance_counterparties }
      t.bigint :onelink_account_id
      t.string :client_name, :title, null: false
      t.string :contract_number, :external_source_key
      t.string :status, null: false, default: 'active'
      t.string :tariff_code, null: false, default: 'custom'
      t.decimal :monthly_amount, :one_time_amount, precision: 15, scale: 2, null: false, default: 0
      t.string :currency, null: false, default: 'KZT'
      t.integer :billing_day
      t.date :starts_on, :ends_on
      t.boolean :medelement_commission_enabled, null: false, default: false
      t.decimal :medelement_commission_rate, precision: 5, scale: 4, null: false, default: 0.3
      t.text :notes
      t.timestamps
    end
    add_contract_indexes
  end

  def add_contract_indexes
    add_index :owner_finance_contracts, :status
    add_index :owner_finance_contracts, :ends_on
    add_index :owner_finance_contracts, :external_source_key, unique: true, where: 'external_source_key IS NOT NULL'
  end

  def create_deadlines_table
    create_table :owner_finance_deadlines do |t|
      t.string :title, null: false
      t.string :category, null: false, default: 'hosting'
      t.string :payer_mode, null: false, default: 'us'
      t.string :provider, :related_domain, :client_name, :external_source_key
      t.references :counterparty, foreign_key: { to_table: :owner_finance_counterparties }
      t.references :contract, foreign_key: { to_table: :owner_finance_contracts }
      t.date :due_on, null: false
      t.decimal :amount, precision: 15, scale: 2, null: false, default: 0
      t.string :currency, null: false, default: 'KZT'
      t.string :recurrence, null: false, default: 'yearly'
      t.string :status, null: false, default: 'active'
      t.integer :remind_days, array: true, null: false, default: [7, 3, 2, 1, 0]
      t.date :last_reminded_on
      t.integer :last_reminded_offset
      t.text :notes
      t.timestamps
    end
    add_deadline_indexes
  end

  def add_deadline_indexes
    add_index :owner_finance_deadlines, %i[status due_on]
    add_index :owner_finance_deadlines, :category
    add_index :owner_finance_deadlines, :external_source_key, unique: true, where: 'external_source_key IS NOT NULL'
  end

  def create_transactions_table
    create_table :owner_finance_transactions do |t|
      t.references :account_record, foreign_key: { to_table: :owner_finance_accounts }
      t.references :counterparty, foreign_key: { to_table: :owner_finance_counterparties }
      t.references :contract, foreign_key: { to_table: :owner_finance_contracts }
      t.date :occurred_on, null: false
      t.string :direction, null: false, default: 'expense'
      t.string :pnl_treatment, null: false, default: 'pnl'
      t.string :official_status, null: false, default: 'management'
      t.string :review_status, null: false, default: 'confirmed'
      t.decimal :amount, :amount_kzt, precision: 15, scale: 2, null: false, default: 0
      t.string :currency, null: false, default: 'KZT'
      t.string :category, null: false, default: 'office_and_ops'
      t.string :merchant, null: false
      t.string :row_fingerprint_sha256, :external_source_key
      t.text :description
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end
    add_transaction_indexes
  end

  def add_transaction_indexes
    add_index :owner_finance_transactions, %i[review_status occurred_on]
    add_index :owner_finance_transactions, %i[pnl_treatment occurred_on]
    add_index :owner_finance_transactions, :row_fingerprint_sha256, unique: true, where: 'row_fingerprint_sha256 IS NOT NULL'
    add_index :owner_finance_transactions, :external_source_key, unique: true, where: 'external_source_key IS NOT NULL'
  end

  def create_tombstones_table
    create_table :owner_finance_personal_tombstones do |t|
      t.string :row_fingerprint_sha256, null: false
      t.string :merchant_key_hash
      t.boolean :hide_merchant_always, null: false, default: false
      t.date :occurred_on
      t.datetime :hidden_at, null: false
      t.timestamps
    end
    add_index :owner_finance_personal_tombstones, :row_fingerprint_sha256, unique: true
    add_index :owner_finance_personal_tombstones, %i[merchant_key_hash hide_merchant_always], name: 'idx_owner_fin_tombstones_merchant_always'
  end

  def create_obligations_table
    create_table :owner_finance_obligations do |t|
      t.references :contract, foreign_key: { to_table: :owner_finance_contracts }
      t.string :entry_kind, null: false, default: 'medelement_commission'
      t.string :title, null: false
      t.string :counterparty_name, :period_label, :external_source_key
      t.decimal :base_amount, :overage_excluded_amount, precision: 15, scale: 2, null: false, default: 0
      t.decimal :amount, :paid_amount, precision: 15, scale: 2, null: false, default: 0
      t.string :currency, null: false, default: 'KZT'
      t.date :due_on, :paid_on
      t.string :status, null: false, default: 'open'
      t.text :notes
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end
    add_obligation_indexes
  end

  def add_obligation_indexes
    add_index :owner_finance_obligations, %i[entry_kind status]
    add_index :owner_finance_obligations, :external_source_key, unique: true, where: 'external_source_key IS NOT NULL'
  end

  def create_sync_states_table
    create_table :owner_finance_sync_states do |t|
      t.string :sync_key, null: false
      t.string :sync_status, null: false, default: 'idle'
      t.datetime :last_synced_at
      t.jsonb :summary, null: false, default: {}
      t.timestamps
    end
    add_index :owner_finance_sync_states, :sync_key, unique: true
  end
end
