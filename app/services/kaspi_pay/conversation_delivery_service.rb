class KaspiPay::ConversationDeliveryService
  MODES = %w[link qr_image].freeze

  def initialize(payment:, conversation:, sender:)
    @payment = payment
    @conversation = conversation
    @sender = sender
  end

  def deliver!(mode:)
    normalized_mode = mode.to_s
    raise ArgumentError, "delivery_mode must be one of: #{MODES.join(', ')}" unless normalized_mode.in?(MODES)

    validate_scope!

    payment.with_lock do
      payment.reload
      existing_message = delivered_message(normalized_mode)

      if existing_message.present?
        delivery_payload(existing_message, normalized_mode, deduplicated: true)
      else
        create_delivery!(normalized_mode)
      end
    end
  end

  private

  attr_reader :conversation, :payment, :sender

  def validate_scope!
    raise ArgumentError, 'Kaspi Pay delivery requires a QR payment' unless payment.payment_type == 'qr'
    raise ArgumentError, 'Kaspi Pay payment belongs to another account' unless payment.account_id == conversation.account_id
    raise ArgumentError, 'Kaspi Pay payment belongs to another conversation' unless payment_conversation_id == conversation.id
  end

  def payment_conversation_id
    return payment.source_id if payment.source_type == 'Conversation'
    return payment.source&.conversation_id if payment.source_type == 'Scheduling::Appointment'
  end

  def create_delivery!(mode)
    policy = ensure_delivery_policy!(mode)
    blob = qr_image_blob(mode)
    message = create_message(delivery_content(mode), blob)
    message.update!(additional_attributes: delivery_attributes(message, policy))
    remember_delivery!(mode, message)

    delivery_payload(message, mode, deduplicated: false)
  rescue StandardError
    blob&.purge_later unless blob&.attachments&.exists?
    raise
  end

  def qr_image_blob(mode)
    return unless mode == 'qr_image'

    KaspiPay::QrImageService.new(payment: payment).create_blob!
  end

  def ensure_delivery_policy!(mode)
    Outbound::DeliveryPolicy.ensure!(
      conversation: conversation,
      content_kind: 'free_text',
      template_params: {},
      attachments: mode == 'qr_image' ? ['kaspi-pay-qr'] : [],
      private_note: false
    )
  end

  def create_message(content, blob)
    params = { content: content, private: false, attachments: Array(blob&.signed_id).compact }
    Messages::MessageBuilder.new(sender, conversation, params).perform
  end

  def delivery_attributes(message, policy)
    (message.additional_attributes || {}).merge('delivery_policy' => policy.as_json)
  end

  def delivery_content(mode)
    key = mode == 'qr_image' ? 'delivery_qr_image' : 'delivery_link'
    options = {
      amount: payment.amount,
      currency: payment.currency,
      payment_url: payment.qr_token
    }

    I18n.with_locale(payment.account.locale.presence || I18n.default_locale) do
      I18n.t("conversations.activity.kaspi_pay.#{key}", **options)
    end
  end

  def delivered_message(mode)
    message_id = payment.metadata.to_h.dig('captain_deliveries', mode, 'message_id')
    return if message_id.blank?

    conversation.messages.outgoing.find_by(id: message_id)
  end

  def remember_delivery!(mode, message)
    deliveries = payment.metadata.to_h.fetch('captain_deliveries', {}).deep_dup
    deliveries[mode] = {
      'message_id' => message.id,
      'delivered_at' => Time.current.iso8601
    }
    payment.update!(metadata: payment.metadata.to_h.merge('captain_deliveries' => deliveries))
  end

  def delivery_payload(message, mode, deduplicated:)
    {
      mode: mode,
      sent: true,
      deduplicated: deduplicated,
      message_id: message.id,
      attachment_ids: message.attachments.map(&:id),
      delivered_at: payment.metadata.to_h.dig('captain_deliveries', mode, 'delivered_at')
    }.compact
  end
end
