# frozen_string_literal: true

class Billing::PaymentMatcher
  def initialize(source:, payload:)
    @source = source.to_s.strip
    raw_hash = payload.is_a?(Hash) ? payload.deep_stringify_keys : {}
    extract_input_fields(raw_hash)
    @raw_payload = Billing.sanitize_sensitive_payload(raw_hash)
  end

  def perform
    raise ArgumentError, 'bank_reference_id is required' if @bank_reference_id.blank?

    existing = find_existing_event
    return existing if existing

    match_and_process!
  rescue ActiveRecord::RecordNotUnique
    find_existing_event || raise
  end

  private

  def extract_input_fields(raw_hash)
    @bank_reference_id = pick_field(raw_hash, 'bank_reference_id', 'reference_id', 'transaction_id', 'rrn').to_s.strip
    @amount_minor = normalize_amount_minor(raw_hash)
    @currency = (pick_field(raw_hash, 'currency').presence || Billing::DEFAULT_CURRENCY).to_s.strip.upcase
    @sender_tax_id = normalize_digits(pick_field(raw_hash, 'sender_tax_id', 'payer_bin'))
    @sender_name = pick_field(raw_hash, 'sender_name', 'payer_name').to_s.strip.presence
    @payment_purpose = pick_field(raw_hash, 'payment_purpose', 'description', 'purpose').to_s.strip
    @explicit_order_code = pick_field(raw_hash, 'invoice_number', 'order_id').to_s.strip
    @occurred_at = parse_time(pick_field(raw_hash, 'occurred_at', 'paid_at'))
  end

  def find_existing_event
    Billing::PaymentEvent.find_by(source: @source, bank_reference_id: @bank_reference_id)
  end

  def match_and_process!
    code = extract_invoice_code
    if code.present?
      invoice_by_code = Billing::Invoice.find_by(invoice_number: code)
      return handle_code_matched_invoice!(invoice_by_code) if invoice_by_code
    end

    match_by_sender_tax_id!
  end

  def handle_code_matched_invoice!(invoice)
    return record_needs_review!(reason: 'ambiguous_purpose', invoice: invoice, account_id: invoice.account_id) unless invoice.open?
    return record_needs_review!(reason: 'ambiguous_purpose', invoice: invoice, account_id: invoice.account_id) unless @currency == invoice.currency
    return record_needs_review!(reason: 'partial_amount', invoice: invoice, account_id: invoice.account_id) if @amount_minor < invoice.amount_minor

    settle_matched_invoice!(invoice)
  end

  def match_by_sender_tax_id!
    return record_needs_review!(reason: 'ambiguous_purpose') unless @sender_tax_id&.match?(Billing::TAX_ID_FORMAT)

    account_ids = matching_account_ids_for_tax_id(@sender_tax_id)
    open_invoices = account_ids.any? ? Billing::Invoice.where(account_id: account_ids, status: Billing::Invoice::OPEN_STATUSES).to_a : []
    single_acc_id = account_ids.one? ? account_ids.first : nil

    return settle_or_partial_single!(open_invoices.first) if open_invoices.one?
    return record_needs_review!(reason: 'multiple_open_invoices', account_id: single_acc_id) if open_invoices.size > 1

    record_needs_review!(reason: 'ambiguous_purpose', account_id: single_acc_id)
  end

  def matching_account_ids_for_tax_id(tax_id)
    profile_ids = Billing::AccountProfile.where(billing_tax_id: tax_id).pluck(:account_id)
    org_ids = Account.joins(:organization).where(organizations: { bin: tax_id }).pluck(:id)
    invoice_ids = Billing::Invoice.where(payer_tax_id: tax_id, status: Billing::Invoice::OPEN_STATUSES).pluck(:account_id)
    (profile_ids + org_ids + invoice_ids).compact.uniq
  end

  def settle_or_partial_single!(invoice)
    return record_needs_review!(reason: 'ambiguous_purpose', invoice: invoice, account_id: invoice.account_id) unless @currency == invoice.currency
    return settle_matched_invoice!(invoice) if @amount_minor == invoice.amount_minor
    return record_needs_review!(reason: 'partial_amount', invoice: invoice, account_id: invoice.account_id) if @amount_minor < invoice.amount_minor

    record_needs_review!(reason: 'ambiguous_purpose', invoice: invoice, account_id: invoice.account_id)
  end

  def settle_matched_invoice!(invoice)
    settled = false
    review_fallback = false
    event = ActiveRecord::Base.transaction do
      invoice.lock!
      existing = find_existing_event
      next existing if existing

      unless invoice.open?
        review_fallback = true
        next persist_needs_review_in_tx!('ambiguous_purpose', invoice, invoice.account_id)
      end

      settled = true
      apply_atomic_settlement!(invoice)
    end
    create_owner_review_task!('ambiguous_purpose', invoice) if review_fallback
    dispatch_post_settlement!(invoice, event) if settled
    event
  end

  def apply_atomic_settlement!(invoice)
    overpaid = @amount_minor > invoice.amount_minor
    invoice.update!(status: 'paid', paid_at: @occurred_at, bank_reference_id: @bank_reference_id)
    profile = Billing::AccountProfile.lock.find_by(account_id: invoice.account_id) ||
              Billing::AccountProfile.create!(account_id: invoice.account_id)
    profile.advance_paid_until!(paid_date: @occurred_at.in_time_zone(Billing::ALMATY_TIMEZONE).to_date, invoice: invoice)
    Billing::OwnerFinanceRecorder.new.record_matched_payment!(
      invoice: invoice, profile: profile, event_attrs: event_attributes, overpaid: overpaid
    )
    Billing::PaymentEvent.create!(
      event_attributes.merge(
        status: 'matched', review_reason: overpaid ? 'overpayment' : nil,
        billing_invoice: invoice, account_id: invoice.account_id,
        metadata: build_event_metadata(invoice: invoice, overpaid: overpaid)
      )
    )
  end

  def dispatch_post_settlement!(invoice, event)
    create_owner_review_task!('overpayment', invoice) if event.review_reason == 'overpayment'
    Billing::ClosingDocumentsJob.perform_later(invoice.id)
    Billing::NotificationService.new(invoice: invoice).deliver_payment_confirmation!
  end

  def record_needs_review!(reason:, invoice: nil, account_id: nil)
    event = ActiveRecord::Base.transaction { persist_needs_review_in_tx!(reason, invoice, account_id) }
    create_owner_review_task!(reason, invoice)
    event
  end

  def persist_needs_review_in_tx!(reason, invoice, account_id)
    Billing::OwnerFinanceRecorder.new.record_needs_review_payment!(
      event_attrs: event_attributes, review_reason: reason, account_id: account_id, invoice: invoice
    )
    Billing::PaymentEvent.create!(
      event_attributes.merge(
        status: 'needs_review', review_reason: reason, billing_invoice: invoice,
        account_id: account_id, metadata: build_event_metadata(invoice: invoice, overpaid: false)
      )
    )
  end

  def build_event_metadata(invoice:, overpaid:)
    meta = overpaid && invoice ? { 'overpayment_minor' => @amount_minor - invoice.amount_minor, 'invoice_amount_minor' => invoice.amount_minor } : {}
    meta['unsupported_currency'] = @currency unless OwnerFinance::SUPPORTED_CURRENCIES.include?(@currency)
    meta
  end

  def create_owner_review_task!(reason, invoice)
    amt_str = format('%<amt>.2f %<cur>s', amt: Billing.minor_to_kzt(@amount_minor), cur: @currency)
    label = reason == 'overpayment' ? '[Переплата по счёту]' : '[Платёж требует проверки]'
    Billing::OwnerTaskService.new.create_idempotent_task!(
      idempotency_key: "billing:payment_review:#{@source}:#{@bank_reference_id}",
      title: "#{label} #{amt_str} · #{@sender_name || @sender_tax_id || @bank_reference_id}",
      description: build_review_description(reason, amt_str, invoice),
      priority: 'high'
    )
  end

  def build_review_description(reason, amt_str, invoice)
    ["Причина: #{reason}", "Источник: #{@source} (ref: #{@bank_reference_id})", "Сумма: #{amt_str}",
     ("Отправитель: #{@sender_name} (БИН/ИИН: #{@sender_tax_id})" if @sender_name || @sender_tax_id),
     ("Счёт: #{invoice.invoice_number}" if invoice),
     ("Назначение: #{@payment_purpose}" if @payment_purpose.present?)].compact.join("\n")
  end

  def event_attributes
    {
      source: @source, bank_reference_id: @bank_reference_id, amount_minor: @amount_minor,
      currency: @currency, sender_tax_id: @sender_tax_id, sender_name: @sender_name,
      payment_purpose: @payment_purpose, occurred_at: @occurred_at, raw_payload: @raw_payload
    }
  end

  def extract_invoice_code
    [@payment_purpose, @explicit_order_code].filter_map { |text| text.to_s[Billing::INVOICE_CODE_REGEX, 1]&.upcase }.first
  end

  def pick_field(hash, *keys)
    keys.lazy.filter_map { |key| hash[key] }.first
  end

  def normalize_amount_minor(raw_hash)
    raw_hash['amount_minor'].present? ? raw_hash['amount_minor'].to_i : Billing.kzt_to_minor(raw_hash['amount'] || 0)
  end

  def normalize_digits(raw)
    raw.to_s.gsub(/\D/, '').presence
  end

  def parse_time(raw)
    return Time.current if raw.blank?
    return raw.to_time if raw.respond_to?(:to_time) && !raw.is_a?(String)

    Time.zone.parse(raw.to_s) || Time.current
  rescue ArgumentError
    Time.current
  end
end
