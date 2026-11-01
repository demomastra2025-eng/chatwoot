# frozen_string_literal: true

class Billing::OwnerFinanceRecorder
  DEFAULT_PARTNER_RATE = BigDecimal('0.30')

  def record_matched_payment!(invoice:, profile:, event_attrs:, overpaid: false)
    contract = find_live_contract(invoice.account_id)
    tx = if supported_currency?(event_attrs[:currency])
           upsert_transaction!(matched_tx_attributes(invoice, profile, contract, event_attrs, overpaid))
         end
    record_partner_obligation_if_applicable!(invoice, profile, contract, event_attrs[:occurred_at])
    tx
  end

  def record_needs_review_payment!(event_attrs:, review_reason:, account_id: nil, invoice: nil)
    return nil unless OwnerFinance::AccountRecord.exists?
    return nil unless supported_currency?(event_attrs[:currency])

    contract = account_id ? find_live_contract(account_id) : nil
    upsert_transaction!(needs_review_tx_attributes(event_attrs, review_reason, contract, invoice))
  end

  private

  def supported_currency?(currency)
    OwnerFinance::SUPPORTED_CURRENCIES.include?(currency.to_s.strip.upcase)
  end

  def upsert_transaction!(attrs)
    rec = OwnerFinance::TransactionRecord.find_or_initialize_by(external_source_key: attrs[:external_source_key])
    rec.update!(attrs)
    rec
  end

  def matched_tx_attributes(invoice, profile, contract, event_attrs, overpaid)
    review_state = overpaid ? 'needs_review' : 'confirmed'
    base_tx_attributes(contract, event_attrs, review_state).merge(
      merchant: resolve_merchant(invoice, profile, event_attrs[:sender_name]),
      description: event_attrs[:payment_purpose].presence || invoice.payment_purpose,
      metadata: matched_tx_metadata(invoice, event_attrs, overpaid)
    )
  end

  def matched_tx_metadata(invoice, event_attrs, overpaid)
    meta = {
      'billing_invoice_id' => invoice.id, 'invoice_number' => invoice.invoice_number,
      'source' => event_attrs[:source], 'bank_reference_id' => event_attrs[:bank_reference_id]
    }
    if overpaid
      meta['review_reason'] = 'overpayment'
      meta['overpayment_minor'] = event_attrs[:amount_minor].to_i - invoice.amount_minor.to_i
    end
    meta
  end

  def needs_review_tx_attributes(event_attrs, review_reason, contract, invoice)
    merchant = (event_attrs[:sender_name].presence || invoice&.payer_legal_name.presence || 'Неопознанный плательщик БЦК').slice(0, 140)
    base_tx_attributes(contract, event_attrs, 'needs_review').merge(
      merchant: merchant,
      description: event_attrs[:payment_purpose].presence || "Требует проверки (#{review_reason})",
      metadata: {
        'review_reason' => review_reason, 'billing_invoice_id' => invoice&.id,
        'source' => event_attrs[:source], 'bank_reference_id' => event_attrs[:bank_reference_id]
      }.compact
    )
  end

  def base_tx_attributes(contract, event_attrs, review_status)
    amt = Billing.minor_to_kzt(event_attrs[:amount_minor])
    cur = event_attrs[:currency].to_s.strip.upcase
    {
      external_source_key: "billing:#{event_attrs[:source]}:#{event_attrs[:bank_reference_id]}",
      account_record_id: resolve_business_account&.id,
      contract_id: contract&.id,
      counterparty_id: contract&.counterparty_id,
      occurred_on: occurred_date(event_attrs[:occurred_at]),
      direction: 'income', pnl_treatment: 'pnl',
      official_status: 'management', review_status: review_status,
      amount: amt, amount_kzt: cur == 'KZT' ? amt : nil, currency: cur,
      category: 'client_subscription'
    }
  end

  def record_partner_obligation_if_applicable!(invoice, profile, contract, occurred_at)
    rate = resolve_commission_rate(profile, contract)
    return nil unless rate&.positive?

    attrs = obligation_attributes(invoice, contract, rate, occurred_at)
    return nil unless attrs[:amount].positive?

    rec = OwnerFinance::Obligation.find_or_initialize_by(
      external_source_key: "billing:medelement_commission:#{invoice.invoice_number}"
    )
    if rec.persisted?
      attrs[:paid_amount] = rec.paid_amount
      attrs[:status] = rec.status
    end
    rec.update!(attrs)
    rec
  end

  def resolve_commission_rate(profile, contract)
    if contract
      return nil unless contract.medelement_commission_enabled?

      return BigDecimal((contract.medelement_commission_rate || DEFAULT_PARTNER_RATE).to_s)
    end
    return BigDecimal(profile.partner_commission_rate_pct.to_s) / 100 if profile.partner_commission_rate_pct.to_i.positive?
    return DEFAULT_PARTNER_RATE if profile.metadata.to_h['medelement_commission_enabled'] == true

    nil
  end

  def obligation_attributes(invoice, contract, rate, occurred_at)
    base_kzt = Billing.minor_to_kzt(invoice.partner_commission_base_minor)
    excluded_minor = [invoice.amount_minor.to_i - invoice.partner_commission_base_minor.to_i, 0].max
    {
      contract_id: contract&.id,
      entry_kind: 'medelement_commission',
      title: "МИС МедЭлемент #{(rate * 100).to_i}% (#{invoice.invoice_number})",
      counterparty_name: 'МИС МедЭлемент',
      period_label: invoice.period_start.strftime('%Y-%m'),
      base_amount: base_kzt,
      overage_excluded_amount: Billing.minor_to_kzt(excluded_minor),
      amount: (base_kzt * rate).round(2),
      paid_amount: 0,
      currency: invoice.currency,
      due_on: occurred_date(occurred_at).end_of_month,
      status: 'open',
      metadata: { 'billing_invoice_id' => invoice.id, 'invoice_number' => invoice.invoice_number }
    }
  end

  def resolve_business_account
    OwnerFinance::AccountRecord.business_liquid.find_by(bank_code: 'bcc') ||
      OwnerFinance::AccountRecord.business_liquid.order(:id).first
  end

  def find_live_contract(account_id)
    OwnerFinance::Contract.live.where(onelink_account_id: account_id).order(id: :desc).first
  end

  def resolve_merchant(invoice, profile, sender_name)
    (invoice.payer_legal_name.presence || sender_name.presence || profile.effective_legal_name.presence || 'Клиент OneLink').slice(0, 140)
  end

  def occurred_date(occurred_at)
    (occurred_at || Time.current).in_time_zone(Billing::ALMATY_TIMEZONE).to_date
  end
end
