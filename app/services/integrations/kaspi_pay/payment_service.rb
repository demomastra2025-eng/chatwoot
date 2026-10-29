# frozen_string_literal: true

class Integrations::KaspiPay::PaymentService
  include Integrations::KaspiPay::PaymentTransitions

  class PaymentError < StandardError; end

  DEFAULT_QR_TTL = 15.minutes
  DEFAULT_INVOICE_TTL = 24.hours
  MAX_AMOUNT_TENGE = 100_000_000

  def initialize(account:, actor: nil)
    @account = account
    @actor = actor
    @auth_service = Integrations::KaspiPay::AuthService.new(account: account)
    @reconciler = Integrations::KaspiPay::AppointmentReconciler.new(account: account, actor: actor)
  end

  def create_payment!(params)
    payment_type, amount = validate_create_inputs!(params)
    hook = @auth_service.hook
    client = @auth_service.build_authenticated_client!(hook)
    context = @reconciler.build_payment_context(params, hook: hook)
    payment = if payment_type == 'qr'
                create_qr_payment!(client, amount, context)
              else
                create_invoice_payment!(client, amount, params[:payer_phone], context)
              end
    finalize_created_payment!(payment, params[:send_to_conversation])
  rescue Integrations::KaspiPay::ApiClient::SessionEvictedError => e
    @auth_service.mark_session_evicted!(e.message)
    raise
  end

  def refresh_payment!(payment, from_polling: false)
    reconcile_unrecorded_paid!(payment) unless from_polling
    return payment unless can_refresh_payment?(payment, from_polling: from_polling)

    refresh_and_check_expiry!(payment)
  rescue Integrations::KaspiPay::ApiClient::SessionEvictedError => e
    handle_refresh_eviction!(payment, e, from_polling: from_polling)
  rescue Integrations::KaspiPay::ApiClient::ApiError => e
    return handle_qr_missing_on_refresh!(payment) if qr_purchase_missing_error?(payment, e)

    raise
  end

  def cancel_payment!(payment)
    unless payment.payment_type == 'invoice'
      raise PaymentError, 'Отмена доступна только для удалённых счетов Kaspi.kz (QR-ссылка истекает автоматически)'
    end
    raise PaymentError, 'Отменить можно только ожидающий оплаты счёт' unless payment.pending?

    @auth_service.build_authenticated_client!.cancel_remote_invoice(operation_id: payment.qr_operation_id)
    cancelled = transition_to_terminal!(
      payment, new_status: 'cancelled', provider_status: 'RemotePaymentCanceled', desc: 'Отменён сотрудником'
    )
    raise PaymentError, 'Счёт уже оплачен или завершён' unless cancelled

    @reconciler.post_activity!(payment.conversation, "Счёт Kaspi Pay ##{payment.qr_operation_id} на #{format_tenge(payment.amount)} отменён.")
    payment
  rescue Integrations::KaspiPay::ApiClient::SessionEvictedError => e
    @auth_service.mark_session_evicted!(e.message)
    raise
  end

  def refund_payment!(payment, return_amount: nil)
    with_refund_lock!(payment) do
      payment.reload
      amount_to_return = validate_refund_amount!(payment, return_amount)
      @auth_service.build_authenticated_client!.refund_payment(qr_operation_id: payment.qr_operation_id, return_amount: amount_to_return)
      apply_refund_state!(payment, amount_to_return)
      @reconciler.record_refund!(payment, amount_returned: amount_to_return)
      post_refund_activity!(payment, amount_to_return)
    end
    payment
  rescue Integrations::KaspiPay::ApiClient::SessionEvictedError => e
    @auth_service.mark_session_evicted!(e.message)
    raise
  end

  def client_info!(raw_phone:)
    phone_10 = Integrations::KaspiPay::PhoneNormalizer.to_kaspi_10_digits!(raw_phone)
    data = @auth_service.build_authenticated_client!.client_info(phone_10: phone_10)
    { phone_masked: Integrations::KaspiPay::PhoneNormalizer.mask(phone_10), client_name: data['ClientName'] || data['Name'] }
  end

  private

  def can_refresh_payment?(payment, from_polling:)
    from_polling ? payment.pending? : payment.refreshable_manually?
  end

  def refresh_and_check_expiry!(payment)
    apply_provider_status!(payment, fetch_provider_status(payment))
    payment.pending? && overdue?(payment) ? expire_overdue_payment!(payment) : payment
  end

  def handle_qr_missing_on_refresh!(payment)
    payment.pending? ? expire_overdue_payment!(payment) : payment
  end

  def reconcile_unrecorded_paid!(payment)
    return unless payment.paid? && payment.appointment_id.present?
    return if (payment.metadata || {})['reconciled_scheduling_payment_id'].present?

    @reconciler.record_payment!(payment)
  end

  def validate_create_inputs!(params)
    payment_type = params[:payment_type].to_s.strip
    unless Integrations::KaspiPay::Payment::PAYMENT_TYPES.include?(payment_type)
      raise PaymentError, 'Некорректный тип оплаты Kaspi Pay (допустимы: qr, invoice)'
    end

    amount = params[:amount].to_i
    raise PaymentError, 'Сумма оплаты должна быть от 1 до 100 000 000 ₸' if amount <= 0 || amount > MAX_AMOUNT_TENGE

    [payment_type, amount]
  end

  def finalize_created_payment!(payment, raw_send_flag)
    @reconciler.post_creation_messages!(payment, send_to_conversation: ActiveModel::Type::Boolean.new.cast(raw_send_flag))
    initial_wait = payment.payment_type == 'qr' ? 4.seconds : 15.seconds
    Integrations::KaspiPay::PollPaymentJob.set(wait: initial_wait).perform_later(payment.id)
    payment
  end

  def create_qr_payment!(client, amount, context)
    res = client.create_qr_token(amount: amount)
    raise PaymentError, 'Kaspi Pay не вернул идентификатор QR-операции' if res[:qr_operation_id].blank?

    @account.kaspi_pay_payments.create!(
      context.merge(
        payment_type: 'qr', status: 'pending', provider_status: 'QrTokenCreated',
        qr_operation_id: res[:qr_operation_id], amount: amount, pay_url: res[:pay_url],
        unified_qr_url: res[:unified_qr_url], receipt_url: res[:receipt_url],
        expires_at: parse_kaspi_time(res[:expire_date]) || DEFAULT_QR_TTL.from_now,
        metadata: { 'behavior_options' => res[:behavior_options] || {} }
      )
    )
  end

  def create_invoice_payment!(client, amount, raw_phone, context)
    phone_10 = Integrations::KaspiPay::PhoneNormalizer.to_kaspi_10_digits!(raw_phone || context[:contact]&.phone_number)
    res = client.create_remote_invoice(phone_10: phone_10, amount: amount, comment: context[:comment].to_s)
    raise PaymentError, 'Kaspi Pay не вернул идентификатор счёта' if res[:qr_operation_id].blank?

    @account.kaspi_pay_payments.create!(
      context.merge(
        payment_type: 'invoice', status: 'pending', provider_status: 'RemotePaymentCreated',
        qr_operation_id: res[:qr_operation_id], order_number: res[:order_number], amount: amount,
        payer_phone_masked: Integrations::KaspiPay::PhoneNormalizer.mask(phone_10),
        receipt_url: res[:receipt_url], expires_at: DEFAULT_INVOICE_TTL.from_now
      )
    )
  end

  def fetch_provider_status(payment)
    client = @auth_service.build_authenticated_client!
    op_id = payment.qr_operation_id
    payment.payment_type == 'qr' ? client.qr_status(qr_operation_id: op_id) : client.remote_invoice_details(operation_id: op_id)
  end

  def handle_refresh_eviction!(payment, error, from_polling:)
    @auth_service.mark_session_evicted!(error.message)
    raise error unless from_polling

    handle_evicted_during_poll!(payment, error.message)
    payment
  end

  def validate_refund_amount!(payment, return_amount)
    raise PaymentError, 'Возврат доступен только для оплаченных транзакций' unless payment.paid?

    amount_to_return = (return_amount.presence || payment.refundable_amount).to_i
    return amount_to_return if amount_to_return.positive? && amount_to_return <= payment.refundable_amount

    raise PaymentError, "Некорректная сумма возврата (доступно до #{format_tenge(payment.refundable_amount)})"
  end

  def post_refund_activity!(payment, amount_to_return)
    msg = "Выполнен возврат Kaspi Pay по операции ##{payment.qr_operation_id} на сумму #{format_tenge(amount_to_return)}."
    @reconciler.post_activity!(payment.conversation, msg)
  end

  def on_payment_succeeded!(payment)
    @reconciler.record_payment!(payment)
    msg = "Оплата Kaspi Pay получена: #{format_tenge(payment.amount)} (операция ##{payment.qr_operation_id})."
    @reconciler.post_activity!(payment.conversation, msg)
  end

  def parse_kaspi_time(raw)
    return nil if raw.blank?

    ActiveSupport::TimeZone[Integrations::KaspiPay::HttpTransport::ALMATY_TZ].parse(raw.to_s)
  rescue ArgumentError
    nil
  end

  def format_tenge(value)
    Integrations::KaspiPay::AppointmentReconciler.format_tenge(value)
  end
end
