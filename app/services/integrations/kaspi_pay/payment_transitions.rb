# frozen_string_literal: true

module Integrations::KaspiPay::PaymentTransitions
  REFUND_LOCK_TTL_SECONDS = 30

  private

  def overdue?(payment)
    payment.expires_at.present? && Time.current > payment.expires_at
  end

  def expire_overdue_payment!(payment)
    transition_to_terminal!(payment, new_status: 'expired', provider_status: 'Expired', desc: 'Время ожидания оплаты истекло')
    payment
  end

  def qr_purchase_missing_error?(payment, error)
    return false unless payment.payment_type == 'qr'

    details = error.details.is_a?(Hash) ? error.details : {}
    error.code.to_i == -99_000_001 && details['Code'].to_i == 18 && details['CodeSubsystem'].to_s.casecmp?('QR')
  end

  def apply_provider_status!(payment, raw_data)
    newly_paid = false
    payment.with_lock do
      attrs, newly_paid = build_status_update_attrs(payment, raw_data)
      return payment unless payment.pending? || (newly_paid && payment.refreshable_manually?)

      payment.update!(attrs)
    end
    on_payment_succeeded!(payment) if newly_paid
    payment
  end

  def build_status_update_attrs(payment, raw_data)
    raw_status = raw_data['Status'].to_s.presence
    resolved = raw_status ? Integrations::KaspiPay::Payment.resolve_internal_status(raw_status) : payment.status
    attrs = base_polled_attrs(payment, raw_data, raw_status)
    attrs[:status] = resolved unless resolved == 'pending'
    attrs[:paid_at] = Time.current if resolved == 'paid'
    [attrs, resolved == 'paid']
  end

  def base_polled_attrs(payment, raw_data, raw_status)
    desc = raw_data['StatusDesc'] || raw_data['StatusDescription']
    {
      poll_attempts: payment.poll_attempts + 1, last_polled_at: Time.current,
      provider_status: raw_status || payment.provider_status,
      provider_status_desc: desc.presence || payment.provider_status_desc,
      receipt_url: raw_data['ReceiptUrl'].presence || payment.receipt_url,
      order_number: raw_data['OrderNumber'].presence || payment.order_number
    }
  end

  def with_refund_lock!(payment)
    lock_key = "kaspi_pay:refund_lock:#{payment.id}"
    token = SecureRandom.uuid
    acquired = ::Redis::Alfred.set(lock_key, token, nx: true, ex: REFUND_LOCK_TTL_SECONDS)
    msg = 'Возврат по этой оплате уже выполняется. Подождите несколько секунд.'
    raise Integrations::KaspiPay::PaymentService::PaymentError, msg unless acquired

    yield
  ensure
    ::Redis::Alfred.delete_if_value(lock_key, token) if acquired
  end

  def apply_refund_state!(payment, amount_to_return)
    payment.with_lock do
      new_refunded = payment.refunded_amount + amount_to_return
      raise Integrations::KaspiPay::PaymentService::PaymentError, 'Сумма возврата превышает сумму оплаты' if new_refunded > payment.amount

      full = new_refunded >= payment.amount
      payment.update!(
        refunded_amount: new_refunded, status: full ? 'refunded' : 'partially_refunded',
        provider_status_desc: full ? 'Полный возврат выполнен' : "Частичный возврат (#{format_tenge(new_refunded)})"
      )
    end
  end

  def transition_to_terminal!(payment, new_status:, provider_status:, desc:)
    transitioned = false
    payment.with_lock do
      next unless payment.pending?

      payment.update!(status: new_status, provider_status: provider_status, provider_status_desc: desc, last_polled_at: Time.current)
      transitioned = true
    end
    transitioned
  end

  def handle_evicted_during_poll!(payment, error_message)
    payment.with_lock do
      return unless payment.pending?

      attempts = payment.poll_attempts + 1
      attrs = { poll_attempts: attempts, last_polled_at: Time.current }
      attrs.merge!(status: 'lost', provider_status: 'SessionExpired', provider_status_desc: error_message) if attempts >= 3
      payment.update!(attrs)
    end
  end
end
