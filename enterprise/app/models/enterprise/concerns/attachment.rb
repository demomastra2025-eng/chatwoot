module Enterprise::Concerns::Attachment
  extend ActiveSupport::Concern

  included do
    after_create_commit :enqueue_audio_transcription
    after_create_commit :enqueue_document_parsing
  end

  private

  def enqueue_audio_transcription
    return unless file_type.to_sym == :audio
    return if message.blank?
    return unless message.account.feature_enabled?('captain_integration')
    return unless message.account.captain_audio_transcription_enabled?

    Messages::AudioTranscriptionJob.perform_later(id)
  end

  def enqueue_document_parsing
    return unless file_type.to_sym == :file
    return if message.blank?
    return unless Messages::DocumentParsingService.enabled_for_account?(message.account)
    return unless Messages::DocumentParsingService.parseable_attachment?(self)

    Messages::DocumentParsingJob.perform_later(id)
  end
end
