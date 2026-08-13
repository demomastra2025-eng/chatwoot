class Campaigns::AudienceImportSourcePurgeService
  SOURCE_RECORD_TYPE = CampaignAudienceImport.polymorphic_name.freeze
  SOURCE_ATTACHMENT_NAME = 'import_file'.freeze

  def initialize(audience_import: nil, attachment_id: nil)
    raise ArgumentError, 'provide one source reference' if audience_import.nil? == attachment_id.nil?

    @audience_import = audience_import
    @attachment_id = attachment_id
  end

  def perform
    attachment = source_attachment
    return if attachment.blank?

    attachment.with_lock do
      blob = attachment.blob
      blob.with_lock do
        if blob.attachments.where.not(id: attachment.id).exists?
          attachment.delete
          next
        end

        blob.service.delete(blob.key)
        attachment.delete
        blob.destroy!
      end
    end
  rescue ActiveRecord::RecordNotFound
    nil
  end

  private

  attr_reader :audience_import, :attachment_id

  def source_attachment
    scope = ActiveStorage::Attachment.where(record_type: SOURCE_RECORD_TYPE, name: SOURCE_ATTACHMENT_NAME)
    return scope.find_by(id: attachment_id) if attachment_id

    scope.find_by(record_id: audience_import.id)
  end
end
