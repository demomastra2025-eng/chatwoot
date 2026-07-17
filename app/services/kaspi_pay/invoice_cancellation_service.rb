class KaspiPay::InvoiceCancellationService
  def initialize(payment:, client: nil)
    @payment = payment
    @client = client || KaspiPay::Client.new(hook: payment.integration_hook)
  end

  def cancel!
    validate!
    response = client.cancel_invoice(payment.kaspi_operation_id)
    if response['StatusCode'].present? && response['StatusCode'].to_i != 0
      raise KaspiPay::Error.new('Kaspi Pay invoice cancellation failed', details: response)
    end

    payment.update!(
      status: 'cancelled',
      failed_at: Time.current,
      metadata: payment.metadata.to_h.merge('cancel_response' => response)
    )
    KaspiPay::ConversationTimelineService.new(payment: payment).record_status!
    payment
  end

  private

  attr_reader :client, :payment

  def validate!
    raise KaspiPay::Error.new('Kaspi Pay payment is not an invoice', code: 'PAYMENT_NOT_INVOICE') unless payment.payment_type == 'invoice'
    raise KaspiPay::Error.new('Kaspi Pay invoice is not cancellable', code: 'PAYMENT_NOT_CANCELLABLE') if payment.final_status?
    return if payment.kaspi_operation_id.present?

    raise KaspiPay::Error.new('Kaspi Pay operation id is missing', code: 'OPERATION_ID_MISSING')
  end
end
