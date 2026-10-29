# frozen_string_literal: true

class Integrations::KaspiPay::PollPaymentJob < ApplicationJob
  queue_as :default

  MAX_POLL_ATTEMPTS = 360

  def perform(payment_id)
    payment = Integrations::KaspiPay::Payment.find_by(id: payment_id)
    return unless pollable?(payment)
    return exhaust_polling!(payment) if payment.poll_attempts >= MAX_POLL_ATTEMPTS

    poll_and_reschedule!(payment)
  rescue Integrations::KaspiPay::ApiClient::ApiError => e
    handle_transient_error(payment, e)
  end

  private

  def pollable?(payment)
    payment.present? && payment.pending?
  end

  def exhaust_polling!(payment)
    payment.with_lock do
      return unless payment.pending?

      payment.update!(
        status: 'lost',
        provider_status: 'PollingExhausted',
        provider_status_desc: 'Превышен лимит проверок статуса платежа'
      )
    end
  end

  def poll_and_reschedule!(payment)
    Integrations::KaspiPay::PaymentService.new(account: payment.account).refresh_payment!(payment, from_polling: true)
    payment.reload
    return unless payment.pending?

    self.class.set(wait: next_poll_interval(payment)).perform_later(payment.id)
  end

  def handle_transient_error(payment, error)
    Rails.logger.warn("[KaspiPay::PollPaymentJob] Transient error for payment ##{payment&.id}: #{error.message}")
    return unless pollable?(payment)

    payment.increment!(:poll_attempts) # rubocop:disable Rails/SkipsModelValidations
    return exhaust_polling!(payment) if payment.poll_attempts >= MAX_POLL_ATTEMPTS

    self.class.set(wait: 15.seconds).perform_later(payment.id)
  end

  def next_poll_interval(payment)
    elapsed = Time.current - payment.created_at
    return 4.seconds if payment.payment_type == 'qr' && elapsed < 2.minutes
    return 15.seconds if elapsed < 15.minutes
    return 60.seconds if elapsed < 30.minutes

    300.seconds
  end
end
