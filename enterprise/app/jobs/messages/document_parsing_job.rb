# frozen_string_literal: true

class Messages::DocumentParsingJob < ApplicationJob
  queue_as :audio_transcription

  retry_on ActiveStorage::FileNotFoundError, wait: 2.seconds, attempts: 3
  retry_on Messages::DocumentParsingService::ProviderError, wait: 5.seconds, attempts: 3 do |job, error|
    Messages::DocumentParsingService.mark_failed(job.arguments.first, error)
  end

  def perform(attachment_id)
    attachment = Attachment.find_by(id: attachment_id)
    return if attachment.blank?

    Messages::DocumentParsingService.new(attachment).perform
  end
end
