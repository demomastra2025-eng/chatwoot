# frozen_string_literal: true

class Confirmations::AttachmentTextExtractor
  STICKER_VISION_PROMPT = <<~PROMPT.squish.freeze
    Examine this customer sticker or image reply to an appointment reminder.
    Extract any visible text (for example "Ок", "Окей", "Да", "Буду", "Спасибо", "Нет", "Отмена")
    and describe any clear gesture or symbol (for example "thumbs up 👍", "checkmark ✅", "OK hand 👌", "thumbs down 👎", "cross ❌").
    Return a short factual phrase in Russian or English.
  PROMPT

  def self.extract(message)
    new(message).extract
  end

  def initialize(message)
    @message = message
  end

  def extract
    return nil if message.blank?

    direct_text = message.content.to_s.strip
    return direct_text if direct_text.present?

    meta_text = extract_from_message_or_attachment_meta
    return meta_text if meta_text.present?

    recognize_visual_attachment
  rescue StandardError => e
    Rails.logger.warn("[Confirmations::AttachmentTextExtractor] Failed for message=#{message&.id}: #{e.class}: #{e.message}")
    nil
  end

  private

  attr_reader :message

  def extract_from_message_or_attachment_meta
    attrs = message.content_attributes.to_h.with_indifferent_access
    emoji_or_caption = attrs[:sticker_emoji].presence ||
                       attrs.dig(:reaction, :emoji).presence ||
                       attrs[:caption].presence
    return emoji_or_caption.to_s.strip if emoji_or_caption.present?

    message.attachments.each do |attachment|
      meta = attachment.meta.to_h.with_indifferent_access
      candidate = meta[:image_recognition_description].presence ||
                  meta[:transcribed_text].presence ||
                  meta[:emoji].presence ||
                  meta[:sticker_emoji].presence ||
                  meta[:caption].presence ||
                  attachment.fallback_title.presence
      return candidate.to_s.strip if candidate.present?
    end

    nil
  end

  def recognize_visual_attachment
    return nil unless defined?(Captain::ImageRecognitionService)

    image_attachment = message.attachments.find { |att| att.file_type.to_s == 'image' }
    return nil if image_attachment.blank?

    image_url = resolve_attachment_url(image_attachment)
    return nil if image_url.blank?

    description = Captain::ImageRecognitionService.new(
      account: message.account,
      attachment: image_attachment,
      image_url: image_url
    ).perform

    return nil if description.blank? || description == Captain::ImageRecognitionService::FALLBACK_DESCRIPTION

    description
  end

  def resolve_attachment_url(attachment)
    return attachment.download_url if attachment.respond_to?(:download_url) && attachment.download_url.present?
    return attachment.external_url if attachment.external_url.present?

    attachment.file.attached? ? attachment.file_url : nil
  end
end
