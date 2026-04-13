class Campaigns::ResumeService
  pattr_initialize [:campaign!]

  def perform
    validate_campaign!

    Campaigns::OneoffRunner.new(
      campaign: campaign,
      contact_ids: resumable_contact_ids,
      retry_source_run: source_run,
      allow_terminal_retry: true,
      resume_run: true
    ).perform
  end

  private

  def validate_campaign!
    raise "Invalid campaign #{campaign.id}" unless campaign.one_off?
    raise 'Campaign already running' if campaign.running?
    raise 'Only failed or cancelled campaigns can be resumed' unless campaign.failed? || campaign.cancelled?
    raise 'No interrupted campaign run found to resume' if source_run.blank?
    raise 'No remaining contacts to resume' if resumable_contact_ids.blank?
  end

  def source_run
    @source_run ||= campaign.campaign_runs
                            .where(status: CampaignRun.statuses.values_at('failed', 'cancelled'))
                            .order(created_at: :desc)
                            .first
  end

  def resumable_contact_ids
    @resumable_contact_ids ||= begin
      processed_ids = source_run.campaign_deliveries.distinct.pluck(:contact_id)

      Campaigns::AudienceResolver.new(
        account: campaign.account,
        audience: campaign.audience
      ).contacts.where.not(id: processed_ids).pluck(:id)
    end
  end
end
