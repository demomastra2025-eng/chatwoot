class KaspiPay::PaymentCreator
  DEFAULT_CURRENCY = 'KZT'.freeze

  def initialize(hook:, source:, amount:, idempotency_key:, payment_type: 'qr', client: nil)
    @hook = hook
    @source = source
    @amount = amount.to_i
    @idempotency_key = idempotency_key
    @payment_type = payment_type
    @client = client || KaspiPay::Client.new(hook: hook)
  end

  def create_qr!
    return create_qr_without_lock! if idempotency_key.blank?

    hook.account.with_lock do
      existing = existing_payment
      existing.presence || create_qr_without_lock!
    end
  end

  private

  attr_reader :amount, :client, :hook, :idempotency_key, :payment_type, :source

  def create_qr_without_lock!
    KaspiPay::Payment.transaction do
      response = client.create_qr(
        amount: amount,
        latitude: hook.settings&.dig('latitude'),
        longitude: hook.settings&.dig('longitude')
      )
      payment = create_payment_from_response!(response)
      KaspiPay::ConversationTimelineService.new(payment: payment).record_created!
      KaspiPay::StatusPollJob.perform_later(payment.id)
      payment
    end
  end

  def existing_payment
    return if idempotency_key.blank?

    KaspiPay::Payment.find_by(account: hook.account, idempotency_key: idempotency_key)
  end

  def create_payment_from_response!(response)
    data = response['Data'] || response['data'] || response
    if response['StatusCode'].present? && response['StatusCode'].to_i != 0
      raise KaspiPay::Error.new('Kaspi Pay QR creation failed', details: response)
    end

    operation_id = data['QrOperationId'] || data['operationId'] || data['id']
    qr_token = data['QrToken'] || data['qrToken'] || data['qrLink']
    if operation_id.blank? || qr_token.blank?
      raise KaspiPay::Error.new('Kaspi Pay QR response is missing required payment identifiers', code: 'QR_RESPONSE_INVALID', details: response)
    end

    KaspiPay::Payment.create!(
      account: hook.account,
      integration_hook: hook,
      source: source,
      payment_type: payment_type,
      amount: (data['Amount'] || amount).to_i,
      currency: DEFAULT_CURRENCY,
      status: 'pending',
      kaspi_operation_id: operation_id,
      qr_token: qr_token,
      receipt_url: data['ReceiptUrl'] || data['receiptUrl'],
      expires_at: parse_time(data['ExpireDate'] || data['expiresAt']),
      idempotency_key: idempotency_key,
      metadata: data
    )
  end

  def parse_time(value)
    return if value.blank?

    Time.zone.parse(value.to_s)
  end
end
