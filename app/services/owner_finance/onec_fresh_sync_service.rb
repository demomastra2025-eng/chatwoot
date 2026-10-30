# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'

class OwnerFinance::OnecFreshSyncService
  DEFAULT_BASE_URL = 'https://1cfresh.kz/a/ea141/211858/odata/standard.odata'
  DEFAULT_AUTH_FILE = '/root/1cfresh_auth.json'

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
    return false if OwnerFinance::PersonalTombstone.hidden_record?(external_source_key: src_key, merchant: attrs[:merchant])

    record = find_or_match_1c_record(src_key, attrs[:occurred_on], direction, amount)
    record.update!(attrs.merge(external_source_key: record.external_source_key.presence || src_key))
    true
  rescue Date::Error
    false
  end

  def find_or_match_1c_record(src_key, occurred_on, direction, amount)
    existing = OwnerFinance::TransactionRecord.find_by(external_source_key: src_key)
    return existing if existing

    matched = OwnerFinance::TransactionRecord
              .where(official_status: 'official_1c', occurred_on: occurred_on, direction: direction, amount: amount)
              .where("external_source_key IS NULL OR external_source_key NOT LIKE '1cfresh:%'")
              .first
    matched || OwnerFinance::TransactionRecord.new(external_source_key: src_key)
  end

  def bank_doc_attributes(doc, direction, amount)
    purpose = doc['НазначениеПлатежа'].to_s.strip
    {
      occurred_on: Date.parse(doc['Date'].to_s), direction: direction,
      pnl_treatment: 'pnl', official_status: 'official_1c', review_status: 'confirmed',
      amount: amount, currency: 'KZT', amount_kzt: amount,
      category: direction == 'income' ? 'client_subscription' : infer_1c_category(purpose),
      merchant: doc['Номер'].present? ? "1С Платёж №#{doc['Номер']}" : 'Банковский ордер 1С',
      description: purpose
    }
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
