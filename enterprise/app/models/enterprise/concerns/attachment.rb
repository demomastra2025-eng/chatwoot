module Enterprise::Concerns::Attachment
  extend ActiveSupport::Concern

  included do
    after_create_commit :enqueue_audio_transcription
    after_create_commit :enqueue_document_parsing
    after_create_commit :enqueue_image_description
  end

  private

  def ai_consent_blocked?
    message&.conversation.present? && Compliance::ExplicitAiConsentGate.blocked?(message.conversation)
  end

  def enqueue_audio_transcription
    return unless file_type.to_sym == :audio
    return if message.blank? || ai_consent_blocked?
    return unless message.account.audio_transcriptions_enabled?

    Messages::AudioTranscriptionJob.perform_later(id)
  end

  def enqueue_document_parsing
    return unless file_type.to_sym == :file
    return if message.blank? || ai_consent_blocked?
    return unless Messages::DocumentParsingService.enabled_for_account?(message.account)
    return unless Messages::DocumentParsingService.parseable_attachment?(self)

    Messages::DocumentParsingJob.perform_later(id)
  end

  # An image of a conversation with an AI agent is described when it arrives, not when an agent needs it (a reply suggestion waited
  # 11.7 s for one on PROD): see Messages::ImageDescriptionService.
  def enqueue_image_description
    return if ai_consent_blocked?
    return unless Messages::ImageDescriptionService.enabled_for?(self)

    Messages::ImageDescriptionJob.perform_later(id)
  rescue StandardError => e
    # The image of a message is never lost over its description: a run describes it when it needs it.
    Rails.logger.warn("[CAPTAIN][ImageDescription] not queued attachment_id=#{id} error_class=#{e.class.name}")
  end
end
