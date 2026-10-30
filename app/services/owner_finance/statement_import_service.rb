# frozen_string_literal: true

class OwnerFinance::StatementImportService
  MAX_UPLOAD_BYTES = 25.megabytes

  BUSINESS_VENDOR_RULES = [
    [/contabo|hetzner|digitalocean|cloudflare/i, 'Contabo / Облачные серверы', 'servers_and_cloud'],
    [/ps\.kz|интернет-компания\s+ps|hoster\.kz/i, 'PS.KZ / ЦОД и домены', 'servers_and_cloud'],
    [/openrouter/i, 'OpenRouter (AI API)', 'ai_and_llm'],
    [/anthropic|claude/i, 'Anthropic / Claude', 'ai_and_llm'],
    [/openai|chatgpt|cursor|elevenlabs|gemini/i, 'AI и инструменты разработки', 'ai_and_llm'],
    [/sip\s*for\s*you|sip\.tg|sipuni|beeline|altel|binotel|tele2/i, 'SIP и телефония', 'telephony'],
    [/1cfresh|1с:фреш|1c\s*fresh/i, '1С:Фреш', 'accounting_and_software'],
    [/facebk|facebook|meta\s*ads/i, 'Meta / Реклама', 'marketing'],
    [/медэлемент|medelement/i, 'МИС МедЭлемент (партнёрская комиссия)', 'partner_commissions'],
    [/кнп\s*(?:910|911|101|103|104|121)|налог|социальные\s+отчисления|енпф|осми/i, 'Налоги и соцплатежи ИП', 'taxes_and_fees']
  ].freeze

  ACCOUNTABLE_TRANSFER_PATTERNS = [
    'со своего счета в kaspi pay',
    'на свой счет в kaspi pay',
    'поступление со своего счета',
    'перевод на свой счет',
    'собственных средств на карту kaspi gold'
  ].freeze

  def initialize(filename:, content:, account_record_id: nil)
    @filename = filename.to_s
    @raw_bytes = content.to_s.b
    @account_record = OwnerFinance::AccountRecord.find_by(id: account_record_id) if account_record_id.present?
  end

  def perform
    validate_upload!
    text = OwnerFinance::StatementParsers.extract_text(@filename, @raw_bytes)
    parsed_rows = OwnerFinance::StatementParsers.detect_and_parse(text)
    counts = persist_parsed_rows(parsed_rows)
    counts.merge(filename: @filename, total_parsed: parsed_rows.size)
  end

  private

  def validate_upload!
    raise ArgumentError, 'Файл пуст' if @raw_bytes.empty?
    raise ArgumentError, 'Файл превышает 25 МБ' if @raw_bytes.bytesize > MAX_UPLOAD_BYTES
  end

  def persist_parsed_rows(parsed_rows)
    counts = { imported_business: 0, queued_for_review: 0, auto_hidden_personal: 0, skipped_duplicates: 0 }
    learned_map = build_learned_counterparty_map
    occ_counter = Hash.new(0)

    ActiveRecord::Base.transaction do
      parsed_rows.each { |row| process_single_row(row, learned_map, occ_counter, counts) }
    end
    counts
  end

  def process_single_row(row, learned_map, occ_counter, counts)
    fingerprint = next_fingerprint(row, occ_counter)
    if already_seen?(fingerprint, row)
      counts[:skipped_duplicates] += 1
      return
    end
    if auto_hide_merchant_row!(row, fingerprint)
      counts[:auto_hidden_personal] += 1
      return
    end

    status = create_classified_transaction!(row, fingerprint, learned_map)
    counts[status == 'needs_review' ? :queued_for_review : :imported_business] += 1
  end

  def next_fingerprint(row, occ_counter)
    norm_key = OwnerFinance.normalize_merchant_key(row[:merchant])
    sig_base = "#{row[:source_type]}|#{row[:occurred_on]}|#{row[:direction]}|#{format('%.2f', row[:amount])}|#{row[:currency]}|#{norm_key}"
    occ_counter[sig_base] += 1
    Digest::SHA256.hexdigest("#{sig_base}|##{occ_counter[sig_base]}")
  end

  def auto_hide_merchant_row!(row, fingerprint)
    return false unless OwnerFinance::PersonalTombstone.always_hidden_merchant?(row[:merchant])

    OwnerFinance::PersonalTombstone.create!(
      row_fingerprint_sha256: fingerprint,
      merchant_key_hash: OwnerFinance::PersonalTombstone.merchant_hash_for(row[:merchant]),
      hide_merchant_always: true,
      occurred_on: row[:occurred_on],
      hidden_at: Time.current
    )
    true
  end

  def create_classified_transaction!(row, fingerprint, learned_map)
    cls = classify_row(row, learned_map)
    OwnerFinance::TransactionRecord.create!(
      occurred_on: row[:occurred_on], direction: cls[:direction], pnl_treatment: cls[:pnl_treatment],
      official_status: row[:official_status] || 'management', review_status: cls[:review_status],
      amount: row[:amount], currency: row[:currency], amount_kzt: OwnerFinance.to_kzt(row[:amount], row[:currency]),
      category: cls[:category], merchant: cls[:merchant], description: row[:description],
      account_record_id: @account_record&.id, row_fingerprint_sha256: fingerprint,
      metadata: { imported_filename: @filename, source_type: row[:source_type] }
    )
    cls[:review_status]
  end

  def already_seen?(fingerprint, row)
    return true if OwnerFinance::TransactionRecord.exists?(row_fingerprint_sha256: fingerprint)
    return true if OwnerFinance::PersonalTombstone.exists?(row_fingerprint_sha256: fingerprint)

    row[:source_type] == '1c_bank' && OwnerFinance::TransactionRecord.exists?(
      official_status: 'official_1c', occurred_on: row[:occurred_on],
      direction: row[:direction], amount: row[:amount]
    )
  end

  def build_learned_counterparty_map
    OwnerFinance::Counterparty.where.not(default_category: [nil, '']).each_with_object({}) do |cp, map|
      map[cp.normalized_key] = {
        merchant: cp.display_name,
        category: cp.default_category,
        pnl_treatment: cp.default_pnl_treatment.presence || 'pnl'
      }
    end
  end

  def classify_row(row, learned_map)
    hay = "#{row[:merchant]} #{row[:description]}".downcase
    return accountable_transfer_classification if ACCOUNTABLE_TRANSFER_PATTERNS.any? { |pat| hay.include?(pat) }

    vendor_match = match_vendor_rule(hay, row[:direction])
    return vendor_match if vendor_match

    learned_match = match_learned_vendor(row, learned_map)
    return learned_match if learned_match

    fallback_classification(row)
  end

  def accountable_transfer_classification
    {
      merchant: 'Подотчётный перевод (Счёт ИП ↔ Карта)',
      direction: 'transfer', category: 'accountable_transfer',
      pnl_treatment: 'non_pnl', review_status: 'confirmed'
    }
  end

  def match_vendor_rule(hay, direction)
    rule = BUSINESS_VENDOR_RULES.find { |regex, _, _| hay.match?(regex) }
    return nil unless rule

    treatment = direction == 'income' ? 'expense_refund' : 'pnl'
    { merchant: rule[1], direction: direction, category: rule[2], pnl_treatment: treatment, review_status: 'confirmed' }
  end

  def match_learned_vendor(row, learned_map)
    norm_key = OwnerFinance.normalize_merchant_key(row[:merchant])
    learned = norm_key.present? ? learned_map[norm_key] : nil
    return nil unless learned

    {
      merchant: learned[:merchant], direction: row[:direction],
      category: learned[:category], pnl_treatment: learned[:pnl_treatment], review_status: 'confirmed'
    }
  end

  def fallback_classification(row)
    if row[:official_status] == 'official_1c'
      return {
        merchant: row[:merchant], direction: row[:direction],
        category: row[:direction] == 'income' ? 'client_subscription' : 'office_and_ops',
        pnl_treatment: 'pnl', review_status: 'confirmed'
      }
    end
    {
      merchant: row[:merchant], direction: row[:direction],
      category: row[:direction] == 'income' ? 'client_subscription' : 'unclassified_card',
      pnl_treatment: row[:is_personal_card] ? 'non_pnl' : 'pnl',
      review_status: row[:is_personal_card] ? 'needs_review' : 'confirmed'
    }
  end
end
