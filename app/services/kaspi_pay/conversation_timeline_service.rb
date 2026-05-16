class KaspiPay::ConversationTimelineService
  EVENT_CREATED = 'created'.freeze
  EVENTS = [EVENT_CREATED, *KaspiPay::Payment::STATUSES].freeze

  def initialize(payment:)
    @payment = payment
    @conversation = payment.source if payment.source.is_a?(Conversation)
  end

  def record_created!
    record_activity!(EVENT_CREATED)
  end

  def record_status!
    return unless payment.final_status?

    record_activity!(payment.status)
  end

  private

  attr_reader :conversation, :payment

  def record_activity!(event)
    return if conversation.blank?
    return unless EVENTS.include?(event)
    return if conversation.messages.exists?(source_id: source_id(event))

    conversation.messages.create!(
      account_id: payment.account_id,
      inbox_id: conversation.inbox_id,
      message_type: :activity,
      content: activity_content(event),
      source_id: source_id(event),
      content_attributes: content_attributes(event)
    )
  rescue ActiveRecord::RecordNotUnique
    nil
  end

  def source_id(event)
    "kaspi-pay:payment:#{payment.id}:#{event}"
  end

  def activity_content(event)
    I18n.t(
      "conversations.activity.kaspi_pay.#{event}",
      amount: payment.amount,
      currency: payment.currency,
      default: fallback_content(event)
    )
  end

  def fallback_content(event)
    case event
    when EVENT_CREATED
      "Kaspi Pay payment link created for #{payment.amount} #{payment.currency}"
    when 'paid'
      "Kaspi Pay payment received: #{payment.amount} #{payment.currency}"
    when 'expired'
      "Kaspi Pay payment link expired: #{payment.amount} #{payment.currency}"
    when 'failed'
      "Kaspi Pay payment failed: #{payment.amount} #{payment.currency}"
    when 'cancelled'
      "Kaspi Pay payment cancelled: #{payment.amount} #{payment.currency}"
    when 'refunded'
      "Kaspi Pay payment refunded: #{payment.amount} #{payment.currency}"
    else
      "Kaspi Pay payment status: #{payment.status}"
    end
  end

  def content_attributes(event)
    {
      data: {
        type: 'kaspi_pay_payment',
        event: event,
        payment_id: payment.id,
        status: payment.status,
        amount: payment.amount,
        currency: payment.currency,
        kaspi_operation_id: payment.kaspi_operation_id
      }.compact
    }
  end
end
