class Campaigns::RestartService
  pattr_initialize [:campaign!]

  def perform
    validate_campaign!

    Campaigns::OneoffRunner.new(
      campaign: campaign,
      retry_source_run: source_run,
      allow_terminal_retry: true,
      restart_run: true
    ).perform
  end

  private

  def validate_campaign!
    raise "Invalid campaign #{campaign.id}" unless campaign.one_off?
    raise 'Campaign already running' if campaign.running?
    raise 'Only failed or cancelled campaigns can be restarted' unless campaign.failed? || campaign.cancelled?
    raise 'No campaign run found to restart from' if source_run.blank?
  end

  def source_run
    @source_run ||= campaign.campaign_runs.order(created_at: :desc).first
  end
end
