class KaspiPay::PaymentCreator
  DEFAULT_CURRENCY = 'KZT'.freeze

  def initialize(hook:, source:, amount:, idempotency_key:, payment_type: 'qr', phone_number: nil, comment: nil, client: nil)
    @hook = hook
    @source = source
    @amount = amount.to_i
    @idempotency_key = idempotency_key
    @payment_type = payment_type.presence || 'qr'
    @phone_number = phone_number
    @comment = comment
    @client = client || KaspiPay::Client.new(hook: hook)
  end

  def create_qr!
    validate_payment_type!('qr')
    with_idempotency_lock { create_qr_without_lock! }
  end

  def create_invoice!
    validate_payment_type!('invoice')
    with_idempotency_lock { create_invoice_without_lock! }
  end

  private

  attr_reader :amount, :client, :comment, :hook, :idempotency_key, :payment_type, :phone_number, :source

  def with_idempotency_lock
    return yield if idempotency_key.blank?

    hook.account.with_lock do
      existing = existing_payment
      existing.presence || yield
    end
  end

  def validate_payment_type!(expected_type)
    return if payment_type == expected_type && payment_type.in?(KaspiPay::Payment::PAYMENT_TYPES)

    raise KaspiPay::Error.new("Kaspi Pay payment_type must be #{expected_type}", code: 'INVALID_PAYMENT_TYPE')
  end

  def create_qr_without_lock!
    KaspiPay::Payment.transaction do
      response = client.create_qr(
        amount: amount,
        latitude: hook.settings&.dig('latitude'),
        longitude: hook.settings&.dig('longitude')
      )
      payment = create_payment_from_response!(response, require_qr_token: true)
      record_created_and_poll!(payment)
    end
  end

  def create_invoice_without_lock!
    normalized_phone = normalize_phone(phone_number.presence || source_phone_number)
    raise KaspiPay::Error.new('Kaspi Pay invoice requires a customer phone number', code: 'PHONE_NUMBER_REQUIRED') if normalized_phone.blank?

    KaspiPay::Payment.transaction do
      response = client.create_invoice(phone_number: normalized_phone, amount: amount, comment: comment)
      payment = create_payment_from_response!(response, require_qr_token: false)
      record_created_and_poll!(payment)
    end
  end

  def record_created_and_poll!(payment)
    KaspiPay::ConversationTimelineService.new(payment: payment).record_created!
    KaspiPay::StatusPollJob.perform_later(payment.id)
    payment
  end

  def existing_payment
    return if idempotency_key.blank?

    KaspiPay::Payment.find_by(account: hook.account, idempotency_key: idempotency_key)
  end

  def create_payment_from_response!(response, require_qr_token:)
    data = response['Data'] || response['data'] || response
    if response['StatusCode'].present? && response['StatusCode'].to_i != 0
      raise KaspiPay::Error.new('Kaspi Pay payment creation failed', details: response)
    end

    operation_id = data['QrOperationId'] || data['Id'] || data['id'] || data['operationId']
    qr_token = data['QrToken'] || data['qrToken'] || data['qrLink']
    if operation_id.blank? || (require_qr_token && qr_token.blank?)
      error_code = require_qr_token ? 'QR_RESPONSE_INVALID' : 'PAYMENT_RESPONSE_INVALID'
      raise KaspiPay::Error.new('Kaspi Pay response is missing required payment identifiers', code: error_code, details: response)
    end

    KaspiPay::Payment.create!(
      account: hook.account,
      integration_hook: hook,
      source: source,
      payment_type: payment_type,
      amount: amount,
      currency: DEFAULT_CURRENCY,
      status: 'pending',
      kaspi_operation_id: operation_id,
      kaspi_order_number: data['OrderNumber'] || data['orderNumber'],
      qr_token: qr_token,
      receipt_url: data['ReceiptUrl'] || data['receiptUrl'],
      expires_at: parse_time(data['ExpireDate'] || data['expiresAt']),
      idempotency_key: idempotency_key,
      metadata: data
    )
  end

  def source_phone_number
    contact = if source.respond_to?(:contact)
                source.contact
              elsif source.respond_to?(:contact_id)
                Contact.find_by(id: source.contact_id, account_id: hook.account_id)
              end
    contact&.phone_number
  end

  def normalize_phone(value)
    digits = value.to_s.gsub(/\D/, '')
    return if digits.blank?

    digits
  end

  def parse_time(value)
    return if value.blank?

    Time.zone.parse(value.to_s)
  end
end
