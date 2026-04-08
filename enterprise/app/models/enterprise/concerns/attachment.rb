module Enterprise::Concerns::Attachment
  extend ActiveSupport::Concern

  included do
    after_create_commit :enqueue_audio_transcription
  end

  private

  def enqueue_audio_transcription
    return unless file_type.to_sym == :audio
    return if message.blank?
    return unless message.account.feature_enabled?('captain_integration')
    return if message.account.audio_transcriptions.blank?

    Messages::AudioTranscriptionJob.perform_later(id)
  end
end
