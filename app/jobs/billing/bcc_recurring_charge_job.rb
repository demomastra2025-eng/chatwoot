# frozen_string_literal: true

class Billing::BccRecurringChargeJob < ApplicationJob
  MAX_ATTEMPTS = 3
  RETRY_INTERVAL = 24.hours

  queue_as :scheduled_jobs

  def perform
    return unless Billing::Config.autobilling_enabled? && Billing::Config.bcc_ecom_configured?

    ensure_due_autopay_invoices!
    due_autopay_invoices.find_each do |invoice|
      attempt_charge_for!(invoice)
    rescue StandardError => e
      Rails.logger.error("[Billing::BccRecurringChargeJob] invoice=#{invoice.invoice_number} error: #{e.class}: #{e.message}")
    end
  end

  private

  def ensure_due_autopay_invoices!
    today = Billing.today_almaty
    Billing::AccountProfile.automatic_periods_through(today)
                           .where(autopay_enabled: true)
                           .includes(:account)
                           .find_each do |profile|
      ensure_autopay_invoice_for_profile!(profile)
    rescue StandardError => e
      Rails.logger.error("[Billing::BccRecurringChargeJob] profile=#{profile.id} ensure error: #{e.class}: #{e.message}")
    end
  end

  def ensure_autopay_invoice_for_profile!(profile)
    return if profile.bcc_card_token.blank? || profile.account.blank?

    Billing::InvoiceGeneratorService.new(account: profile.account, notify: false).perform(automatic_through: Billing.today_almaty)
  end

  def due_autopay_invoices
    Billing::Invoice.joins(account: :billing_account_profile)
                    .where(status: Billing::Invoice::OPEN_STATUSES)
                    .where('billing_invoices.due_on <= ?', Billing.today_almaty)
                    .where('billing_invoices.recurring_attempts_count <= ?', MAX_ATTEMPTS)
                    .where(billing_account_profiles: { billing_enabled: true, autopay_enabled: true })
                    .where("billing_invoices.metadata -> 'completion_v1' ->> 'managed' = 'true'")
                    .includes(account: :billing_account_profile)
  end

  def attempt_charge_for!(invoice)
    attempt_num, card_token, token, recorded = claim_recurring_attempt(invoice)
    return unless attempt_num

    res = recorded || execute_ecom_charge(invoice, card_token)
    return unless save_charge_receipt!(invoice, attempt_num, token, res)

    res[:approved] ? settle_approved_charge!(invoice, res) : handle_failed_attempt!(invoice, res[:message], attempt_num)
  rescue StandardError => e
    Billing::CompletionState.new(invoice).fail!("recurring_charge_#{attempt_num}", token, error: e) if token
    raise
  end

  def save_charge_receipt!(invoice, attempt_num, token, res)
    return true unless token

    validate_charge_response!(res)
    Billing::CompletionState.new(invoice).finish!("recurring_charge_#{attempt_num}", token,
                                                  receipt: Billing.sanitize_sensitive_payload(res).deep_stringify_keys)
  end

  def claim_recurring_attempt(invoice)
    Account.find(invoice.account_id).with_lock('FOR NO KEY UPDATE') do
      invoice.lock!
      state = Billing::CompletionState.new(invoice)
      profile = Billing::AccountProfile.find_by(account_id: invoice.account_id)
      return nil unless claimable_invoice?(invoice, state, profile)

      previous_num = invoice.recurring_attempts_count
      recorded = existing_charge_result(invoice, state)
      return nil if recorded == :blocked
      return [previous_num, nil, nil, recorded] if recorded
      return nil unless next_attempt_due?(invoice)

      next_attempt = previous_num + 1
      token = state.claim!("recurring_charge_#{next_attempt}", configured: Billing::Config.bcc_ecom_configured?)
      return nil unless token

      invoice.update!(recurring_attempts_count: next_attempt, last_recurring_attempt_at: Time.current)
      [next_attempt, profile.bcc_card_token, token, nil]
    end
  end

  def chargeable_profile?(profile)
    profile.present? && profile.billing_enabled? && profile.autopay_enabled? && profile.bcc_card_token.present?
  end

  def claimable_invoice?(invoice, state, profile)
    invoice.open? && state.managed? && chargeable_profile?(profile)
  end

  def next_attempt_due?(invoice)
    invoice.recurring_attempts_count < MAX_ATTEMPTS && !recently_attempted?(invoice)
  end

  def existing_charge_result(invoice, state)
    number = invoice.recurring_attempts_count
    previous = state.step("recurring_charge_#{number}")
    if number.positive? && previous.empty?
      state.hold!("recurring_charge_#{number}", 'missing_recurring_receipt')
      return :blocked
    end
    if previous['state'].in?(%w[running needs_review])
      state.claim!("recurring_charge_#{number}", configured: true) if previous['state'] == 'running'
      return :blocked
    end
    completed_charge_result(previous, number)
  end

  def completed_charge_result(previous, number)
    return unless previous['state'] == 'completed' && previous['receipt'].is_a?(Hash)

    recorded = previous['receipt'].deep_symbolize_keys
    recorded if recorded[:approved] || number >= MAX_ATTEMPTS
  end

  def recently_attempted?(invoice)
    invoice.last_recurring_attempt_at.present? && invoice.last_recurring_attempt_at > RETRY_INTERVAL.ago
  end

  def execute_ecom_charge(invoice, card_token)
    raise 'Billing recurring IO requires a committed transaction' if ActiveRecord::Base.connection.open_transactions.positive?

    Billing::BccEcomClient.new.charge_recurring!(invoice: invoice, card_token: card_token)
  end

  def validate_charge_response!(res)
    known_decline = res[:status].to_s.in?(%w[declined rejected failed insufficient_funds]) && res[:raw_payload].present?
    valid = res[:approved] == true ? res[:bank_reference_id].present? : known_decline
    raise Billing::BccEcomClient::ApiError, 'Ambiguous recurring response' unless valid
  end

  def settle_approved_charge!(invoice, res)
    ref_id = res.fetch(:bank_reference_id)
    Billing::PaymentMatcher.new(
      source: 'bcc_ecom',
      payload: {
        bank_reference_id: ref_id, invoice_number: invoice.invoice_number,
        amount_minor: invoice.amount_minor, currency: invoice.currency,
        payment_purpose: invoice.payment_purpose, raw_payload: res[:raw_payload]
      }
    ).perform
  end

  def handle_failed_attempt!(invoice, error_message, attempt_num)
    invoice.with_lock do
      return unless invoice.open?

      meta = invoice.metadata.merge('last_recurring_error' => error_message.to_s.slice(0, 160))
      meta['recurring_exhausted_at'] ||= Time.current.iso8601 if attempt_num >= MAX_ATTEMPTS
      invoice.update!(metadata: meta)
    end
    return unless attempt_num >= MAX_ATTEMPTS

    Billing::InvoiceGeneratorService.resume!(invoice)
    Billing::NotificationService.new(invoice: invoice).deliver_recurring_fallback!
  end
end
