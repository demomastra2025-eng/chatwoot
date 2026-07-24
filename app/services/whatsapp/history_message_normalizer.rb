module Whatsapp::HistoryMessageNormalizer
  MEDIA_TYPES = %w[audio document image sticker video].freeze
  PLACEHOLDER_CONTENT = '[Media unavailable in imported WhatsApp history]'.freeze

  module_function

  def importable(message)
    return message unless message[:type].to_s == 'media_placeholder'

    message.merge(type: 'text', text: { body: PLACEHOLDER_CONTENT })
  end

  def media_follow_up?(existing_message, message)
    existing_message.content_attributes.to_h['whatsapp_history_original_type'] == 'media_placeholder' &&
      MEDIA_TYPES.include?(message[:type].to_s)
  end
end
