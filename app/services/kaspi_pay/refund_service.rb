class KaspiPay::RefundService
  def initialize(payment:, return_amount:, client: nil)
    @payment = payment
    @return_amount = return_amount.to_i
    @client = client || KaspiPay::Client.new(hook: payment.integration_hook)
  end

  def refund!
    validate_refundable!

    response = client.create_refund(qr_operation_id: payment.kaspi_operation_id, return_amount: return_amount)
    raise KaspiPay::Error.new('Kaspi Pay refund failed', details: response) if response['StatusCode'].present? && response['StatusCode'].to_i != 0

    refund_amount = refunded_amount + return_amount
    metadata = payment.metadata.to_h.merge(
      'last_refund_response' => response['Data'] || response['data'] || response,
      'refund_amount' => refund_amount
    )
    attrs = { metadata: metadata }
    if refund_amount >= payment.amount
      attrs[:status] = 'refunded'
      attrs[:failed_at] = Time.current
    end

    payment.update!(attrs)
    KaspiPay::ConversationTimelineService.new(payment: payment).record_status! if payment.status == 'refunded'
    payment
  end

  private

  attr_reader :client, :payment, :return_amount

  def validate_refundable!
    raise KaspiPay::Error.new('Refund amount must be greater than 0', code: 'INVALID_REFUND_AMOUNT') if return_amount <= 0
    raise KaspiPay::Error.new('Kaspi Pay operation id is missing', code: 'OPERATION_ID_MISSING') if payment.kaspi_operation_id.blank?

    unless payment.payment_type == 'qr' && payment.status == 'paid'
      raise KaspiPay::Error.new('Kaspi Pay payment is not refundable', code: 'PAYMENT_NOT_REFUNDABLE')
    end

    return if return_amount <= remaining_refundable_amount

    raise KaspiPay::Error.new('Refund amount exceeds remaining refundable amount', code: 'REFUND_AMOUNT_EXCEEDS_REMAINING')
  end

  def refunded_amount
    payment.metadata.to_h['refund_amount'].to_i
  end

  def remaining_refundable_amount
    payment.amount - refunded_amount
  end
end
