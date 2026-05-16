class KaspiPay::PayloadBuilder
  class << self
    def hook(hook)
      return { connected: false } if hook.blank?

      {
        id: hook.id,
        app_id: hook.app_id,
        connected: hook.enabled?,
        status: hook.status,
        settings: safe_hook_settings(hook),
        metadata: hook.kaspi_pay_metadata,
        created_at: hook.created_at,
        updated_at: hook.updated_at
      }
    end

    def payment(payment)
      return {} if payment.blank?

      {
        id: payment.id,
        payment_type: payment.payment_type,
        amount: payment.amount,
        currency: payment.currency,
        status: payment.status,
        status_description: payment.status_description,
        source_type: payment.source_type,
        source_id: payment.source_id,
        source: source_payload(payment.source),
        qr_token: payment.qr_token,
        receipt_url: payment.receipt_url,
        expires_at: payment.expires_at,
        paid_at: payment.paid_at,
        failed_at: payment.failed_at,
        kaspi_operation_id: payment.kaspi_operation_id,
        kaspi_order_number: payment.kaspi_order_number,
        created_at: payment.created_at,
        updated_at: payment.updated_at
      }.compact
    end

    private

    def safe_hook_settings(hook)
      hook.settings.to_h.slice('default_payment_type', 'latitude', 'longitude')
    end

    def source_payload(source)
      case source
      when Conversation
        {
          type: 'Conversation',
          id: source.id,
          display_id: source.display_id,
          contact_id: source.contact_id,
          inbox_id: source.inbox_id
        }
      when Scheduling::Appointment
        {
          type: 'Scheduling::Appointment',
          id: source.id,
          contact_id: source.contact_id,
          conversation_id: source.conversation_id,
          service_id: source.service_id,
          service_amount: source.service_amount,
          prepaid_amount: source.prepaid_amount,
          settlement_amount: source.settlement_amount,
          payment_status: source.payment_status
        }
      end
    end
  end
end
