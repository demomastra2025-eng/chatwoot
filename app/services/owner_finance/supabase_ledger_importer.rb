# frozen_string_literal: true

class OwnerFinance::SupabaseLedgerImporter
  PERSONAL_SKIP_CATEGORIES = %w[
    owner_draw personal_non_business_funds housing_rent
    childcare_kindergarten childcare_nanny child_formula
  ].freeze
  SUPERSEDED_CATEGORIES = %w[superseded_overlap_duplicate superseded_bank_side_error].freeze

  def initialize(conn:, account_map:, cp_map:, contract_map:, stats:)
    @conn = conn
    @account_map = account_map
    @cp_map = cp_map
    @contract_map = contract_map
    @stats = stats
  end

  def perform!
    import_tombstones!
    import_transactions!
    import_commissions!
    import_debts!
    import_onec_state!
  end

  private

  def import_tombstones!
    rows = @conn.exec(<<~SQL.squish)
      SELECT transaction_fingerprint_sha256 AS fp, deleted_at
      FROM biz.personal_transaction_tombstones
      WHERE transaction_fingerprint_sha256 IS NOT NULL
      UNION
      SELECT source_row_hash AS fp, deleted_at
      FROM biz.statement_transaction_tombstones
      WHERE source_row_hash IS NOT NULL
    SQL
    rows.each { |row| upsert_tombstone!(row['fp'], row['deleted_at']) }
  end

  def upsert_tombstone!(fingerprint, deleted_at)
    tb = OwnerFinance::PersonalTombstone.find_or_initialize_by(row_fingerprint_sha256: fingerprint)
    tb.hidden_at ||= OwnerFinance::SupabaseRowMappers.parse_time(deleted_at)
    tb.save!
    @stats[:personal_tombstones] += 1
  end

  def import_transactions!
    rows = @conn.exec(<<~SQL.squish)
      SELECT t.id, t.account_id, t.counterparty_id, cp.display_name AS cp_name, t.contract_id,
             t.occurred_at, t.direction, t.scope, t.pnl_treatment, t.official_status,
             t.category, t.amount, t.currency, t.description, t.metadata
      FROM biz.transactions t LEFT JOIN biz.counterparties cp ON cp.id = t.counterparty_id ORDER BY t.id
    SQL
    rows.each { |row| import_single_transaction!(row) }
  end

  def import_single_transaction!(row)
    return if SUPERSEDED_CATEGORIES.include?(row['category'].to_s)
    return record_migrated_tombstone!(row) if personal_supabase_row?(row)

    src_key = "supabase:tx:#{row['id']}"
    attrs = OwnerFinance::SupabaseLedgerRowMappers.transaction_attrs(row, @account_map, @cp_map, @contract_map)
    return if hidden_or_duplicate?(attrs, src_key, row['id'])

    rec = OwnerFinance::TransactionRecord.find_or_initialize_by(external_source_key: src_key)
    rec.update!(attrs)
    @stats[:business_transactions] += 1
  end

  def personal_supabase_row?(row)
    row['scope'] == 'personal' || PERSONAL_SKIP_CATEGORIES.include?(row['category'].to_s)
  end

  def record_migrated_tombstone!(row)
    fp = Digest::SHA256.hexdigest("supabase:personal_tx:#{row['id']}")
    tb = OwnerFinance::PersonalTombstone.find_or_initialize_by(row_fingerprint_sha256: fp)
    tb.occurred_on ||= OwnerFinance::SupabaseRowMappers.parse_date(row['occurred_at'])
    tb.hidden_at ||= Time.current
    tb.save!
    @stats[:personal_tombstones] += 1
  end

  def hidden_or_duplicate?(attrs, src_key, row_id)
    if OwnerFinance::PersonalTombstone.hidden_record?(
      fingerprint: attrs[:row_fingerprint_sha256], external_source_key: src_key, merchant: attrs[:merchant]
    )
      return true
    end
    return false if attrs[:row_fingerprint_sha256].blank?

    OwnerFinance::TransactionRecord.where.not(external_source_key: "supabase:tx:#{row_id}")
                                   .exists?(row_fingerprint_sha256: attrs[:row_fingerprint_sha256])
  end

  def import_commissions!
    rows = @conn.exec(<<~SQL.squish)
      SELECT co.id, co.contract_id, cp.display_name AS cp_name, co.period_label, co.source_amount,
             co.accrued_amount, co.paid_amount, co.currency, co.due_at, co.paid_at, co.status, co.notes, co.metadata
      FROM biz.commission_obligations co LEFT JOIN biz.counterparties cp ON cp.id = co.counterparty_id ORDER BY co.id
    SQL
    rows.each do |row|
      rec = OwnerFinance::Obligation.find_or_initialize_by(external_source_key: "supabase:comm:#{row['id']}")
      rec.update!(OwnerFinance::SupabaseLedgerRowMappers.commission_obligation_attrs(row, @contract_map))
      @stats[:obligations] += 1
    end
  end

  def import_debts!
    rows = @conn.exec(<<~SQL.squish)
      SELECT d.id, d.debt_type, cp.display_name AS cp_name, d.contract_id,
             d.principal_amount, d.currency, d.due_at, d.status, d.description
      FROM biz.debts d LEFT JOIN biz.counterparties cp ON cp.id = d.counterparty_id
      WHERE d.scope = 'business' ORDER BY d.id
    SQL
    rows.each do |row|
      rec = OwnerFinance::Obligation.find_or_initialize_by(external_source_key: "supabase:debt:#{row['id']}")
      rec.update!(OwnerFinance::SupabaseLedgerRowMappers.debt_obligation_attrs(row, @contract_map))
      @stats[:obligations] += 1
    end
  end

  def import_onec_state!
    rows = @conn.exec('SELECT sync_status, last_synced_at, summary FROM biz.onec_sync_state ORDER BY id DESC LIMIT 1')
    return if rows.ntuples.zero?

    row = rows[0]
    sb_time = OwnerFinance::SupabaseRowMappers.parse_time(row['last_synced_at'])
    rec = OwnerFinance::SyncState.find_or_initialize_by(sync_key: 'onec_fresh')
    return if rec.persisted? && rec.last_synced_at.present? && rec.last_synced_at > sb_time

    rec.update!(
      sync_status: row['sync_status'].presence || 'ok',
      last_synced_at: sb_time,
      summary: OwnerFinance::SupabaseRowMappers.parse_json(row['summary'])
    )
  end
end
