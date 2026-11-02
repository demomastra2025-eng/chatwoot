# frozen_string_literal: true

# Diagnostic only. Run outside an application transaction; PostgreSQL enforces zero writes.
class Billing::FoundationPreflight
  TABLES = %w[billing_accounts billing_account_workspaces billing_subscriptions].freeze

  def self.report
    connection = ApplicationRecord.connection
    raise ArgumentError, 'preflight requires its own read-only transaction' if connection.transaction_open?

    connection.transaction do
      connection.execute('SET TRANSACTION READ ONLY')
      new(connection).report
    end
  end

  def initialize(connection)
    @connection = connection
  end

  def report
    tables = TABLES.index_with { |table| @connection.table_exists?(table) }
    return { ready: false, codes: ['foundation_tables_missing'], tables: tables } unless tables.values.all?
    return { ready: false, codes: ['foundation_schema_unmanaged'], tables: tables } unless managed_schema?

    pending = TABLES.index_with { |table| @connection.select_values("SELECT id FROM #{table} WHERE foundation_state = 'legacy_pending' ORDER BY id") }
    invalid = invalid_contract_ids
    codes = diagnostic_codes(pending, invalid)
    { ready: codes.empty?, tables: tables, legacy_pending: pending,
      invalid_subscription_ids: invalid, codes: codes, scope: 'foundation_only' }
  end

  private

  def diagnostic_codes(pending, invalid)
    codes = []
    codes << 'legacy_mapping_required' if pending.values.any?(&:any?)
    codes << 'invalid_subscription_contract' if invalid.any?
    codes
  end

  def managed_schema?
    TABLES.all? { |table| @connection.column_exists?(table, :foundation_state) } &&
      @connection.column_exists?(:billing_account_workspaces, :starts_at) &&
      @connection.column_exists?(:billing_accounts, :organization_id) && @connection.column_exists?(:billing_accounts, :standalone_account_id)
  end

  def invalid_contract_ids
    BillingSubscription.ready.order(:id).filter_map do |subscription|
      subscription.id unless subscription.billing_account.ready? && Billing::PlanSnapshot.valid?(subscription.plan_snapshot,
                                                                                                 subscription.price_snapshot)
    end
  end
end
