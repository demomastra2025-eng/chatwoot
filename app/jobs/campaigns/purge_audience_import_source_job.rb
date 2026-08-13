class Campaigns::PurgeAudienceImportSourceJob < ApplicationJob
  queue_as :housekeeping
  retry_on StandardError, wait: :polynomially_longer, attempts: 10

  def perform(audience_import_id)
    audience_import = CampaignAudienceImport.find_by(id: audience_import_id)
    return if audience_import.blank?

    audience_import.with_lock do
      audience_import.reload
      next unless audience_import.completed? || audience_import.failed?

      Campaigns::AudienceImportSourcePurgeService.new(audience_import: audience_import).perform
    end
  end
end
