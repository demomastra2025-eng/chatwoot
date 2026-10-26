# frozen_string_literal: true

# Describes an image when it arrives (Messages::ImageDescriptionService). It shares the queue of the document parsing, which is also
# worked by every AI worker; an image whose description is not ready when a run needs it is described by the run.
class Messages::ImageDescriptionJob < ApplicationJob
  queue_as :audio_transcription

  retry_on ActiveStorage::FileNotFoundError, wait: 2.seconds, attempts: 3
  retry_on Messages::ImageDescriptionService::NotReady, wait: 3.seconds, attempts: 4 do |job, error|
    Rails.logger.info("[CAPTAIN][ImageDescription] attachment_id=#{job.arguments.first} left for the run: #{error.message}")
  end

  def perform(attachment_id)
    attachment = Attachment.find_by(id: attachment_id)
    return if attachment.blank?

    Messages::ImageDescriptionService.new(attachment).perform
  end
end
