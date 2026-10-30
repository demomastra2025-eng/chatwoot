# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'

class OwnerFinance::OnecFreshSyncService
  DEFAULT_BASE_URL = 'https://1cfresh.kz/a/ea141/211858/odata/standard.odata'
  DEFAULT_AUTH_FILE = '/root/1cfresh_auth.json'
  GENERIC_MERCHANT_REGEX = /\A(1С Платёж|Банковский ордер 1С)/
  EXTRA_TRANSFER_PATTERNS = [
    'подотчет', 'подотчёт', 'собственных средств', 'на личную карту', 'доход ип'
  ].freeze

  def initialize(days_back: 45)
    @days_back = days_back
  end

  def perform
    creds = resolve_credentials
    return record_not_configured unless creds

    sync_with_credentials(creds)
  rescue StandardError => e
    clean_err = sanitize_error_message(e.message)
    OwnerFinance::SyncState.record!('onec_fresh', status: 'error', summary: { error: clean_err })
    raise ArgumentError, clean_err
  end

  private

  def sanitize_error_message(msg)
    msg.to_s.gsub(%r{https?://[^@/\s]+@}, 'https://[REDACTED]@').slice(0, 200)
  end

  def record_not_configured
    state = OwnerFinance::SyncState.record!(
      'onec_fresh',
      status: 'not_configured',
      summary: { message: 'Учётные данные OData 1С:Фреш не заданы на этом сервере' }
    )
    state.summary.merge('status' => state.sync_status)
  end

  def sync_with_credentials(creds)
    since_iso = (OwnerFinance.today_almaty - @days_back.days).strftime('%Y-%m-%dT00:00:00')
    incoming = fetch_odata(creds, odata_doc_query('Document_ПлатежноеПоручениеВходящее', since_iso))
    outgoing = fetch_odata(creds, odata_doc_query('Document_ПлатежноеПоручениеИсходящее', since_iso))
    upserted = persist_docs(incoming, outgoing)
    summary = {
      incoming_fetched: incoming.size, outgoing_fetched: outgoing.size,
      transactions_upserted: upserted, synced_at: Time.current.iso8601
    }
    OwnerFinance::SyncState.record!('onec_fresh', status: 'ok', summary: summary)
    summary.merge('status' => 'ok')
  end

  def odata_doc_query(entity_name, since_iso)
    "#{entity_name}?$format=json&$filter=Posted%20eq%20true%20and%20Date%20ge%20datetime'#{since_iso}'&$orderby=Date%20desc&$top=200"
  end

  def persist_docs(incoming, outgoing)
    upserted = 0
    ActiveRecord::Base.transaction do
      incoming.each { |doc| upserted += 1 if upsert_bank_doc(doc, direction: 'income') }
      outgoing.each { |doc| upserted += 1 if upsert_bank_doc(doc, direction: 'expense') }
    end
    upserted
  end

  def resolve_credentials
    base_url = ENV.fetch('ONEC_FRESH_ODATA_URL', DEFAULT_BASE_URL)
    credentials_from_env(base_url) || credentials_from_file(base_url)
  end

  def credentials_from_env(base_url)
    user = ENV['ONEC_FRESH_USER'].presence
    password = ENV['ONEC_FRESH_PASSWORD'].presence
    user && password ? { base_url: base_url, user: user, password: password } : nil
  end

  def credentials_from_file(base_url)
    return nil unless File.exist?(DEFAULT_AUTH_FILE)

    parsed = JSON.parse(File.read(DEFAULT_AUTH_FILE))
    user = (parsed['user'] || parsed['username']).presence
    password = parsed['password'].presence
    return nil unless user && password

    { base_url: parsed['odata_url'].presence || base_url, user: user, password: password }
  rescue JSON::ParserError
    nil
  end

  def fetch_odata(creds, relative_query)
    uri = URI("#{creds[:base_url].chomp('/')}/#{relative_query}")
    raise ArgumentError, '1С:Фреш OData требует HTTPS' unless uri.scheme == 'https'

    req = Net::HTTP::Get.new(uri, 'Accept' => 'application/json')
    req.basic_auth(creds[:user], creds[:password])
    res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: 15, read_timeout: 30) { |http| http.request(req) }
    raise "1С:Фреш OData HTTP #{res.code}" unless res.is_a?(Net::HTTPSuccess)

    Array(JSON.parse(res.body)['value'])
  end

  def upsert_bank_doc(doc, direction:)
    ref_key = doc['Ref_Key'].to_s.strip
    amount = BigDecimal((doc['СуммаДокумента'] || 0).to_s)
    return false if ref_key.blank? || amount <= 0

    src_key = "1cfresh:#{direction}:#{ref_key}"
    attrs = bank_doc_attributes(doc, direction, amount)
    return false if hidden_in_tombstones?(src_key, attrs[:merchant])

    persist_bank_doc(src_key, direction, amount, attrs)
  rescue Date::Error
    false
  end

  def persist_bank_doc(src_key, direction, amount, attrs)
    record = find_or_match_1c_record(src_key, attrs[:occurred_on], [direction, attrs[:direction]].uniq, amount)
    return false if record.persisted? && hidden_in_tombstones?(record.external_source_key, record.merchant)

    record.update!(merged_1c_attributes(record, src_key, attrs))
    true
  end

  def hidden_in_tombstones?(source_key, merchant)
    OwnerFinance::PersonalTombstone.hidden_record?(external_source_key: source_key, merchant: merchant)
  end

  def find_or_match_1c_record(src_key, occurred_on, directions, amount)
    existing = OwnerFinance::TransactionRecord.find_by(external_source_key: src_key)
    return existing if existing

    matched = OwnerFinance::TransactionRecord
              .where(official_status: 'official_1c', occurred_on: occurred_on, direction: directions, amount: amount)
              .where("external_source_key IS NULL OR external_source_key NOT LIKE '1cfresh:%'")
              .order(:id)
              .first
    matched || OwnerFinance::TransactionRecord.new(external_source_key: src_key)
  end

  def merged_1c_attributes(record, src_key, attrs)
    return attrs.merge(external_source_key: src_key) unless record.persisted?

    attrs.merge(
      external_source_key: src_key,
      direction: record.direction,
      pnl_treatment: record.pnl_treatment,
      category: record.category,
      merchant: preserve_merchant?(record.merchant) ? record.merchant : attrs[:merchant],
      description: record.description.presence || attrs[:description],
      metadata: merged_source_metadata(record, src_key)
    )
  end

  def preserve_merchant?(merchant)
    merchant.present? && !merchant.match?(GENERIC_MERCHANT_REGEX)
  end

  def merged_source_metadata(record, src_key)
    meta = record.metadata || {}
    prev_key = record.external_source_key
    return meta if prev_key.blank? || prev_key == src_key

    meta.merge('previous_external_source_key' => prev_key)
  end

  def bank_doc_attributes(doc, direction, amount)
    purpose = doc['НазначениеПлатежа'].to_s.strip
    transfer = accountable_transfer?(direction, purpose)
    {
      occurred_on: Date.parse(doc['Date'].to_s),
      direction: transfer ? 'transfer' : direction,
      pnl_treatment: transfer ? 'non_pnl' : 'pnl',
      official_status: 'official_1c', review_status: 'confirmed',
      amount: amount, currency: 'KZT', amount_kzt: amount,
      category: resolve_1c_category(direction, purpose, transfer),
      merchant: default_1c_merchant(doc, transfer),
      description: purpose
    }
  end

  def resolve_1c_category(direction, purpose, transfer)
    return 'accountable_transfer' if transfer
    return 'client_subscription' if direction == 'income'

    infer_1c_category(purpose)
  end

  def default_1c_merchant(doc, transfer)
    return 'Подотчётный перевод (Счёт ИП ↔ Карта)' if transfer

    doc['Номер'].present? ? "1С Платёж №#{doc['Номер']}" : 'Банковский ордер 1С'
  end

  def accountable_transfer?(direction, purpose)
    return false unless direction == 'expense'

    low = purpose.downcase
    patterns = OwnerFinance::StatementImportService::ACCOUNTABLE_TRANSFER_PATTERNS + EXTRA_TRANSFER_PATTERNS
    patterns.any? { |pat| low.include?(pat) }
  end

  def infer_1c_category(purpose)
    low = purpose.downcase
    return 'taxes_and_fees' if low.match?(/налог|соц|пенсион|осми|кнп/)
    return 'servers_and_cloud' if low.match?(/хостинг|сервер|домен|интернет-компания ps/)
    return 'partner_commissions' if low.match?(/медэлемент|партнер|комисси/)
    return 'payroll_and_contractors' if low.match?(/зарплат|оплат.*услуг.*разработ/)

    'office_and_ops'
  end
end
