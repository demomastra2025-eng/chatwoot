class Whatsapp::TemplateMediaCleanupJob < ApplicationJob
  queue_as :housekeeping

  def perform(blob_id)
    blob = ActiveStorage::Blob.find_by(id: blob_id)
    return if blob.blank? || blob.attachments.exists?

    blob.purge
  end
end
