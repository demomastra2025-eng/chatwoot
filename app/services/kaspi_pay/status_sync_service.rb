class KaspiPay::StatusSyncService
  EXPIRE_GRACE_PERIOD = 2.minutes
  DEFAULT_MAX_POLL_AGE = 30.minutes

  STATUS_MAP = {
    'processed' => 'paid',
    'paid' => 'paid',
    'success' => 'paid',
    'expired' => 'expired',
    'canceled' => 'cancelled',
    'cancelled' => 'cancelled',
    'failed' => 'failed',
    'declined' => 'failed',
    'error' => 'failed',
    'returned' => 'refunded',
    'refunded' => 'refunded'
  }.freeze

  def initialize(payment:, client: nil)
    @payment = payment
    @client = client || KaspiPay::Client.new(hook: payment.integration_hook)
  end

  def sync!
    return payment if payment.final_status?

    previous_status = payment.status
    data = status_data
    new_status = map_status(data['Status'] || data['status'])
    return expire_by_ttl!(last_status_response: data) if new_status == 'pending' && expired_by_ttl?

    attrs = {
      status: new_status,
      status_description: data['StatusDesc'] || data['statusDesc'] || data['description'],
      receipt_url: data['ReceiptUrl'] || data['receiptUrl'] || payment.receipt_url,
      metadata: payment.metadata.to_h.merge('last_status_response' => data)
    }
    attrs[:paid_at] = Time.current if new_status == 'paid'
    attrs[:failed_at] = Time.current if new_status.in?(%w[expired failed cancelled refunded])

    KaspiPay::Payment.transaction do
      payment.update!(attrs)
      record_domain_payment_once! if payment.status == 'paid'
      record_conversation_status_once! if payment.final_status? && previous_status != payment.status
    end

    payment
  end

  private

  attr_reader :client, :payment

  def status_data
    response = payment.payment_type == 'invoice' ? client.invoice_details(payment.kaspi_operation_id) : client.qr_status(payment.kaspi_operation_id)
    if response['StatusCode'].present? && response['StatusCode'].to_i != 0
      raise KaspiPay::Error.new('Kaspi Pay status request failed', details: response)
    end

    response['Data'] || response['data'] || response
  end

  def expired_by_ttl?
    return Time.current >= payment.expires_at + EXPIRE_GRACE_PERIOD if payment.expires_at.present?

    Time.current >= payment.created_at + DEFAULT_MAX_POLL_AGE
  end

  def expire_by_ttl!(last_status_response: nil)
    metadata = payment.metadata.to_h.merge('expired_locally_at' => Time.current.iso8601)
    metadata['last_status_response'] = last_status_response if last_status_response.present?

    KaspiPay::Payment.transaction do
      payment.update!(
        status: 'expired',
        status_description: I18n.t('conversations.activity.kaspi_pay.expired', amount: payment.amount, currency: payment.currency),
        failed_at: Time.current,
        metadata: metadata
      )
      record_conversation_status_once!
    end

    payment
  end

  def map_status(provider_status)
    STATUS_MAP.fetch(provider_status.to_s.downcase, 'pending')
  end

  def record_conversation_status_once!
    KaspiPay::ConversationTimelineService.new(payment: payment).record_status!
  end

  def record_domain_payment_once!
    return unless payment.source.is_a?(Scheduling::Appointment)
    return if linked_scheduling_payment_recorded?

    existing_payment_ids = payment.source.payments.ids

    Scheduling::Appointments::FinanceSyncService.new(appointment: payment.source).add_payment!(
      amount: payment.amount,
      payment_method: payment.payment_type == 'invoice' ? 'kaspi_invoice' : 'kaspi_qr'
    )

    scheduling_payment = payment.source.payments
                                .where(payment_method: payment.payment_type == 'invoice' ? 'kaspi_invoice' : 'kaspi_qr', payment_kind: 'payment', amount: payment.amount)
                                .where.not(id: existing_payment_ids)
                                .order(:created_at, :id)
                                .last
    return if scheduling_payment.blank?

    payment.update!(metadata: payment.metadata.to_h.merge('scheduling_payment_id' => scheduling_payment.id))
  end

  def linked_scheduling_payment_recorded?
    scheduling_payment_id = payment.metadata.to_h['scheduling_payment_id']
    return false if scheduling_payment_id.blank?

    payment.source.payments.exists?(id: scheduling_payment_id)
  end
end
