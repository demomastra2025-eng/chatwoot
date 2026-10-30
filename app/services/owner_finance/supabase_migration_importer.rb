# frozen_string_literal: true

require 'pg'

class OwnerFinance::SupabaseMigrationImporter
  DEFAULT_URL_FILE = '/root/supabase_url.txt'

  def initialize(supabase_url: nil)
    @supabase_url = supabase_url.presence || ENV['SUPABASE_FINANCE_DATABASE_URL'].presence || read_default_url_file
  end

  def perform
    raise ArgumentError, 'Не задан SUPABASE_FINANCE_DATABASE_URL' if @supabase_url.blank?

    conn = open_readonly_connection
    stats = empty_stats
    ActiveRecord::Base.transaction do
      run_all_imports!(conn, stats)
      OwnerFinance::SyncState.record!('supabase_migration', status: 'ok', summary: stats)
    end
    stats
  ensure
    conn&.close
  end

  private

  def open_readonly_connection
    conn = PG.connect(@supabase_url)
    conn.exec('SET SESSION CHARACTERISTICS AS TRANSACTION READ ONLY')
    conn
  end

  def empty_stats
    {
      accounts: 0, counterparties: 0, contracts: 0, deadlines: 0,
      business_transactions: 0, personal_tombstones: 0, obligations: 0
    }
  end

  def run_all_imports!(conn, stats)
    account_map = import_accounts!(conn, stats)
    cp_map = import_counterparties!(conn, stats)
    contract_map = import_contracts!(conn, cp_map, stats)
    import_external_deadlines!(conn, stats)
    import_recurring_obligations!(conn, cp_map, contract_map, stats)
    OwnerFinance::SupabaseLedgerImporter.new(
      conn: conn, account_map: account_map, cp_map: cp_map, contract_map: contract_map, stats: stats
    ).perform!
  end

  def read_default_url_file
    File.exist?(DEFAULT_URL_FILE) ? File.read(DEFAULT_URL_FILE).strip : nil
  end

  def import_accounts!(conn, stats)
    rows = conn.exec(<<~SQL.squish)
      SELECT a.id, a.name, a.scope, a.account_type, a.currency, a.is_active, a.notes,
             COALESCE(SUM(CASE
               WHEN t.direction IN ('income', 'transfer_in') THEN t.amount
               WHEN t.direction IN ('expense', 'transfer_out') THEN -t.amount
               ELSE 0 END), 0) AS computed_balance
      FROM biz.accounts a LEFT JOIN biz.transactions t ON t.account_id = a.id
      WHERE a.scope = 'business'
      GROUP BY a.id ORDER BY a.id
    SQL
    rows.each_with_object({}) do |row, map|
      rec = OwnerFinance::AccountRecord.find_or_initialize_by(external_source_key: "supabase:account:#{row['id']}")
      attrs = OwnerFinance::SupabaseRowMappers.account_attrs(row)
      attrs.delete(:current_balance) if rec.persisted? && rec.current_balance.to_d.positive?
      rec.update!(attrs)
      map[row['id'].to_s] = rec.id
      stats[:accounts] += 1
    end
  end

  def import_counterparties!(conn, stats)
    rows = conn.exec(business_counterparties_sql)
    rows.each_with_object({}) do |row, map|
      rec = upsert_counterparty!(row, "supabase:cp:#{row['id']}")
      map[row['id'].to_s] = rec.id
      stats[:counterparties] += 1
    end
  end

  def business_counterparties_sql
    <<~SQL.squish
      SELECT id, COALESCE(NULLIF(display_name, ''), legal_name) AS display_name, counterparty_type, bin_iin, notes
      FROM biz.counterparties
      WHERE id IN (
        SELECT counterparty_id FROM biz.contracts WHERE counterparty_id IS NOT NULL
        UNION SELECT counterparty_id FROM biz.recurring_obligations WHERE scope = 'business' AND counterparty_id IS NOT NULL
        UNION SELECT counterparty_id FROM biz.transactions WHERE scope = 'business' AND counterparty_id IS NOT NULL
        UNION SELECT counterparty_id FROM biz.commission_obligations WHERE counterparty_id IS NOT NULL
        UNION SELECT counterparty_id FROM biz.debts WHERE scope = 'business' AND counterparty_id IS NOT NULL
      )
      ORDER BY id
    SQL
  end

  def upsert_counterparty!(row, src_key)
    norm = unique_cp_norm_key(row, src_key)
    rec = OwnerFinance::Counterparty.find_by(external_source_key: src_key) ||
          OwnerFinance::Counterparty.find_or_initialize_by(normalized_key: norm)
    rec.update!(
      external_source_key: src_key, display_name: row['display_name'].presence || "Контрагент ##{row['id']}",
      normalized_key: norm, kind: OwnerFinance::SupabaseRowMappers.map_cp_kind(row['counterparty_type']),
      bin_iin: row['bin_iin'], notes: row['notes']
    )
    rec
  end

  def unique_cp_norm_key(row, src_key)
    norm = OwnerFinance.normalize_merchant_key(row['display_name'])
    collision = norm.blank? || OwnerFinance::Counterparty.where.not(external_source_key: src_key).exists?(normalized_key: norm)
    collision ? "#{norm.presence || 'cp'}-#{row['id']}" : norm
  end

  def import_contracts!(conn, cp_map, stats)
    rows = conn.exec(<<~SQL.squish)
      SELECT c.id, c.counterparty_id, cp.display_name AS client_name, c.contract_number,
             c.title, c.status, c.amount, c.currency, c.payment_terms, c.starts_at, c.ends_at,
             c.notes, c.metadata, c.commission_applicability, c.commission_expected_rate
      FROM biz.contracts c
      LEFT JOIN biz.counterparties cp ON cp.id = c.counterparty_id
      LEFT JOIN biz.contract_types ct ON ct.id = c.contract_type_id
      WHERE ct.category IS NULL OR ct.category = 'business'
      ORDER BY c.id
    SQL
    rows.each_with_object({}) do |row, map|
      rec = OwnerFinance::Contract.find_or_initialize_by(external_source_key: "supabase:contract:#{row['id']}")
      rec.update!(OwnerFinance::SupabaseRowMappers.contract_attrs(row, cp_map))
      map[row['id'].to_s] = rec.id
      stats[:contracts] += 1
    end
  end

  def import_external_deadlines!(conn, stats)
    rows = conn.exec(<<~SQL.squish)
      SELECT id, provider, service_type, service_name, related_domain, due_date, amount, currency, status, metadata
      FROM biz.external_service_deadlines ORDER BY id
    SQL
    rows.each do |row|
      due_on = OwnerFinance::SupabaseRowMappers.parse_date(row['due_date'])
      next unless due_on

      rec = OwnerFinance::Deadline.find_or_initialize_by(external_source_key: "supabase:ext_deadline:#{row['id']}")
      rec.update!(OwnerFinance::SupabaseRowMappers.external_deadline_attrs(row, due_on))
      stats[:deadlines] += 1
    end
  end

  def import_recurring_obligations!(conn, cp_map, contract_map, stats)
    rows = conn.exec(<<~SQL.squish)
      SELECT r.id, r.name, r.category, r.counterparty_id, cp.display_name AS cp_name,
             r.contract_id, r.amount, r.currency, r.frequency, r.next_due_at, r.status, r.notes
      FROM biz.recurring_obligations r LEFT JOIN biz.counterparties cp ON cp.id = r.counterparty_id
      WHERE r.scope = 'business' ORDER BY r.id
    SQL
    rows.each do |row|
      due_on = OwnerFinance::SupabaseRowMappers.parse_date(row['next_due_at'])
      next unless due_on

      rec = OwnerFinance::Deadline.find_or_initialize_by(external_source_key: "supabase:recurring:#{row['id']}")
      rec.update!(OwnerFinance::SupabaseRowMappers.recurring_deadline_attrs(row, cp_map, contract_map, due_on))
      stats[:deadlines] += 1
    end
  end
end
