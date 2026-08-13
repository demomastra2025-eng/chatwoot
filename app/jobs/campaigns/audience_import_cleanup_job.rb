class Campaigns::AudienceImportCleanupJob < ApplicationJob
  queue_as :housekeeping
  retry_on StandardError, wait: :polynomially_longer, attempts: 10

  def perform(audience_import_id = nil)
    enqueue_terminal_source_purges
    purge_orphaned_sources

    return cleanup_target(audience_import_id) if audience_import_id

    cleanup_expired_imports
  end

  private

  def enqueue_terminal_source_purges
    CampaignAudienceImport.where(status: [:completed, :failed]).joins(:import_file_attachment).find_each do |audience_import|
      Campaigns::ProcessAudienceImportJob.enqueue_source_purge(audience_import)
    end
  end

  def purge_orphaned_sources
    orphaned_source_attachments.find_each do |attachment|
      Campaigns::AudienceImportSourcePurgeService.new(attachment_id: attachment.id).perform
    end
  end

  def orphaned_source_attachments
    ActiveStorage::Attachment
      .where(
        record_type: Campaigns::AudienceImportSourcePurgeService::SOURCE_RECORD_TYPE,
        name: Campaigns::AudienceImportSourcePurgeService::SOURCE_ATTACHMENT_NAME
      )
      .where.not(record_id: CampaignAudienceImport.select(:id))
  end

  def cleanup_target(audience_import_id)
    audience_import = CampaignAudienceImport.find_by(id: audience_import_id)
    cleanup_import(audience_import) if audience_import
  end

  def cleanup_expired_imports
    CampaignAudienceImport.where(expires_at: ..Time.current).find_each do |audience_import|
      cleanup_import(audience_import, require_expired: true)
    end
  end

  def cleanup_import(audience_import, require_expired: false)
    audience_import.with_lock do
      audience_import.reload
      next if require_expired && audience_import.expires_at.future?
      next if Campaign.exists?(campaign_audience_import_id: audience_import.id)

      Campaigns::AudienceImportSourcePurgeService.new(audience_import: audience_import).perform
      audience_import.destroy!
    end
  rescue ActiveRecord::RecordNotFound
    nil
  end
end
