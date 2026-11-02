# frozen_string_literal: true

class CreateBillingUnitLedger < ActiveRecord::Migration[7.1]
  TABLES = %i[billing_usage_periods billing_usage_projections billing_usage_revisions].freeze

  def up
    raise ActiveRecord::MigrationError, 'unit ledger tables already exist: review their origin' if TABLES.any? { |table| local_table?(table) }

    create_periods
    create_projections
    create_revisions
  end

  def down
    raise ActiveRecord::IrreversibleMigration, 'Keep financial unit history; rollback application code without deleting the ledger.'
  end

  private

  def local_table?(table)
    connection.select_value("SELECT to_regclass(quote_ident(current_schema()) || '.' || #{connection.quote(table.to_s)})::text").present?
  end

  def create_periods
    create_table :billing_usage_periods do |table|
      table.references :billing_account, null: false, foreign_key: true
      table.references :billing_subscription, null: false, foreign_key: true
      table.date :month, null: false
      period_terms(table)
      table.bigint :dialogs_count, null: false, default: 0
      table.bigint :call_seconds, null: false, default: 0
      table.bigint :revision, null: false, default: 0
      table.timestamps
    end
    add_index :billing_usage_periods, %i[billing_account_id month], unique: true, name: 'idx_billing_usage_period_owner_month'
    add_check_constraint :billing_usage_periods, 'EXTRACT(DAY FROM month) = 1', name: 'chk_billing_usage_period_month'
    add_check_constraint :billing_usage_periods, 'dialogs_count >= 0 AND call_seconds >= 0 AND revision >= 0', name: 'chk_billing_usage_period_units'
    add_check_constraint :billing_usage_periods, 'anchor_ends_at > anchor_starts_at', name: 'chk_billing_usage_period_anchor'
    add_check_constraint :billing_usage_periods,
                         "jsonb_typeof(plan_snapshot) = 'object' AND jsonb_typeof(price_snapshot) = 'object'",
                         name: 'chk_billing_usage_period_terms'
  end

  def period_terms(table)
    table.jsonb :plan_snapshot, null: false, default: {}
    table.jsonb :price_snapshot, null: false, default: {}
    table.datetime :anchor_starts_at, null: false
    table.datetime :anchor_ends_at, null: false
  end

  def create_projections
    create_table :billing_usage_projections do |table|
      table.references :account, null: false, foreign_key: true
      table.string :kind, null: false
      table.bigint :subject_id, null: false
      table.bigint :version, null: false
      projection_data(table)
      table.bigint :retired_into_id
      table.datetime :retired_at
      table.timestamps
    end
    add_foreign_key :billing_usage_projections, :billing_usage_projections, column: :retired_into_id
    add_index :billing_usage_projections, %i[account_id kind subject_id], unique: true, name: 'idx_billing_usage_projection_subject'
    add_check_constraint :billing_usage_projections, "kind IN ('contact','call') AND subject_id > 0 AND version > 0",
                         name: 'chk_billing_usage_projection_identity'
    add_check_constraint :billing_usage_projections, '(retired_at IS NULL) = (retired_into_id IS NULL)',
                         name: 'chk_billing_usage_projection_retirement'
    add_check_constraint :billing_usage_projections,
                         "jsonb_typeof(sources) = 'object' AND jsonb_typeof(allocations) = 'object' AND jsonb_typeof(window_sources) = 'array'",
                         name: 'chk_billing_usage_projection_payload'
  end

  def projection_data(table)
    table.string :fingerprint, null: false, limit: 64
    table.jsonb :sources, null: false, default: {}
    table.jsonb :allocations, null: false, default: {}
    table.jsonb :window_sources, null: false, default: []
  end

  def create_revisions
    create_table :billing_usage_revisions do |table|
      table.references :billing_usage_period, null: false, foreign_key: true
      table.references :billing_usage_projection, null: false, foreign_key: true
      table.bigint :revision, null: false
      table.bigint :projection_version, null: false
      table.bigint :dialogs_delta, null: false
      table.bigint :seconds_delta, null: false
      table.timestamps
    end
    revision_indexes
    add_check_constraint :billing_usage_revisions,
                         'revision > 0 AND projection_version > 0 AND (dialogs_delta <> 0 OR seconds_delta <> 0)',
                         name: 'chk_billing_usage_revision_nonzero'
  end

  def revision_indexes
    add_index :billing_usage_revisions, %i[billing_usage_period_id revision], unique: true, name: 'idx_billing_usage_revision_order'
    keys = %i[billing_usage_projection_id projection_version billing_usage_period_id]
    add_index :billing_usage_revisions, keys, unique: true, name: 'idx_billing_usage_revision_operation'
  end
end
