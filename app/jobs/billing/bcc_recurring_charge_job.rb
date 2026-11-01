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
    Billing::AccountProfile.enabled
                           .where(autopay_enabled: true)
                           .where('paid_until <= ?', today)
                           .includes(:account)
                           .find_each do |profile|
      ensure_autopay_invoice_for_profile!(profile)
    rescue StandardError => e
      Rails.logger.error("[Billing::BccRecurringChargeJob] profile=#{profile.id} ensure error: #{e.class}: #{e.message}")
    end
  end

  def ensure_autopay_invoice_for_profile!(profile)
    return if profile.bcc_card_token.blank? || profile.account.blank?

    Billing::InvoiceGeneratorService.new(
      account: profile.account, period_start: profile.paid_until, due_on: profile.paid_until, notify: false
    ).perform
  end

  def due_autopay_invoices
    Billing::Invoice.joins(account: :billing_account_profile)
                    .where(status: Billing::Invoice::OPEN_STATUSES)
                    .where('billing_invoices.due_on <= ?', Billing.today_almaty)
                    .where('billing_invoices.recurring_attempts_count < ?', MAX_ATTEMPTS)
                    .where(billing_account_profiles: { billing_enabled: true, autopay_enabled: true })
                    .includes(account: :billing_account_profile)
  end

  def attempt_charge_for!(invoice)
    attempt_num, card_token = claim_recurring_attempt(invoice)
    return unless attempt_num

    res = execute_ecom_charge(invoice, card_token)
    res[:approved] ? settle_approved_charge!(invoice, res, attempt_num) : handle_failed_attempt!(invoice, res[:message], attempt_num)
  end

  def claim_recurring_attempt(invoice)
    invoice.with_lock do
      profile = invoice.account&.billing_account_profile
      return nil if !invoice.open? || profile.blank? || profile.bcc_card_token.blank?
      return nil if invoice.recurring_attempts_count >= MAX_ATTEMPTS || recently_attempted?(invoice)

      next_attempt = invoice.recurring_attempts_count + 1
      invoice.update!(recurring_attempts_count: next_attempt, last_recurring_attempt_at: Time.current)
      [next_attempt, profile.bcc_card_token]
    end
  end

  def recently_attempted?(invoice)
    invoice.last_recurring_attempt_at.present? && invoice.last_recurring_attempt_at > RETRY_INTERVAL.ago
  end

  def execute_ecom_charge(invoice, card_token)
    Billing::BccEcomClient.new.charge_recurring!(invoice: invoice, card_token: card_token)
  rescue Billing::BccEcomClient::ApiError => e
    { approved: false, message: e.message, raw_payload: {} }
  end

  def settle_approved_charge!(invoice, res, attempt_num)
    ref_id = res[:bank_reference_id].presence || "bcc-ecom-rec-#{invoice.id}-#{attempt_num}"
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
    meta = invoice.metadata.merge('last_recurring_error' => error_message.to_s.slice(0, 160))
    if attempt_num >= MAX_ATTEMPTS
      meta['recurring_exhausted_at'] = Time.current.iso8601
      invoice.update!(
        payment_url: invoice.payment_url.presence || Billing::BccEcomClient.new.build_payment_url(invoice),
        metadata: meta
      )
      Billing::NotificationService.new(invoice: invoice).deliver_recurring_fallback!
    else
      invoice.update!(metadata: meta)
    end
  end
end
