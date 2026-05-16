class KaspiPay::HistoryReconciliationService
  def initialize(payment:, operation_method: 0, client: nil)
    @payment = payment
    @operation_method = operation_method
    @client = client || KaspiPay::Client.new(hook: payment.integration_hook)
  end

  def sync!
    validate_reconcilable!

    response = client.operation_details(payment.kaspi_operation_id, operation_method: operation_method)
    if response['StatusCode'].present? && response['StatusCode'].to_i != 0
      raise KaspiPay::Error.new('Kaspi Pay operation details request failed', details: response)
    end

    data = response['Data'] || response['data'] || response
    refund_amount = total_refund_amount(data)
    metadata = payment.metadata.to_h.merge('last_operation_details' => data)
    metadata['refund_amount'] = refund_amount if refund_amount.positive?

    return payment.update!(metadata: metadata) && payment if refund_amount <= 0

    payment.update!(
      status: refund_amount >= payment.amount ? 'refunded' : payment.status,
      failed_at: refund_amount >= payment.amount ? Time.current : payment.failed_at,
      metadata: metadata
    )
    KaspiPay::ConversationTimelineService.new(payment: payment).record_status! if payment.status == 'refunded'
    payment
  end

  private

  attr_reader :client, :operation_method, :payment

  def validate_reconcilable!
    return if payment.payment_type == 'qr' && payment.kaspi_operation_id.to_s.match?(/\A\d+\z/)

    raise KaspiPay::Error.new('Kaspi Pay reconciliation requires a QR payment with a numeric operation id', code: 'PAYMENT_NOT_RECONCILABLE')
  end

  def total_refund_amount(data)
    returns = Array(data['Returns'] || data['returns'])
    returns.sum { |row| (row['Amount'] || row['amount']).to_i }
  end
end
