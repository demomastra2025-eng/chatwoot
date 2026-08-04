# frozen_string_literal: true

class Confirmations::TelegramTerminalFeedbackService
  STATUS_LABELS = {
    'confirmed' => '✅ Подтверждено',
    'declined' => '❌ Отменено',
    'reschedule_requested' => '🔄 Запрошен перенос',
    'expired' => '⌛ Срок подтверждения истёк'
  }.freeze
  EMPTY_INLINE_KEYBOARD = { inline_keyboard: [] }.to_json.freeze

  pattr_initialize [:confirmation_request!]

  def perform
    return false unless telegram_delivery?

    channel.update_message(
      message: delivery_message,
      content: terminal_content,
      reply_markup: EMPTY_INLINE_KEYBOARD
    )
    persist_terminal_state!
    true
  rescue StandardError => e
    Rails.logger.warn(
      "Telegram confirmation terminal feedback failed for request #{confirmation_request.id}: #{e.class} - #{e.message}"
    )
    false
  end

  private

  def telegram_delivery?
    STATUS_LABELS.key?(confirmation_request.status) &&
      delivery_message.present? &&
      delivery_message.source_id.present? &&
      channel.is_a?(Channel::Telegram)
  end

  def persist_terminal_state!
    delivery_message.update!(
      content: terminal_content,
      content_type: 'text',
      content_attributes: delivery_message.content_attributes.to_h.merge(
        'items' => [],
        'edited' => true,
        'confirmation_status' => confirmation_request.status,
        'confirmation_resolved_at' => confirmation_request.resolved_at&.iso8601
      ).compact
    )
  end

  def terminal_content
    @terminal_content ||= [
      confirmation_request.title,
      confirmation_request.body,
      STATUS_LABELS.fetch(confirmation_request.status)
    ].compact_blank.join("\n\n")
  end

  def delivery_message
    @delivery_message ||= confirmation_request.delivery_message
  end

  def channel
    confirmation_request.inbox&.channel
  end
end
