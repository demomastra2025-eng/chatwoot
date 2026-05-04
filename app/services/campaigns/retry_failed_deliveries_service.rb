class Campaigns::RetryFailedDeliveriesService
  RETRYABLE_DELIVERY_STATUSES = %w[failed skipped].freeze
  STALE_RETRYABLE_DELIVERY_STATUSES = %w[pending submitted sent].freeze

  pattr_initialize [:campaign!]

  def perform
    validate_campaign!

    Campaigns::OneoffRunner.new(
      campaign: campaign,
      contact_ids: retry_contact_ids,
      retry_source_run: source_run,
      allow_terminal_retry: true
    ).perform
  end

  private

  def validate_campaign!
    raise "Invalid campaign #{campaign.id}" unless campaign.one_off?
    raise 'Campaign already running' if campaign.running?
    raise 'Cancelled campaigns cannot be retried' if campaign.cancelled?
    raise 'No retryable campaign run found' if source_run.blank?
    raise 'No failed deliveries to retry' if retry_contact_ids.blank?
  end

  def source_run
    @source_run ||= campaign.campaign_runs
                            .where(id: retryable_delivery_scope.select(:campaign_run_id))
                            .distinct
                            .order(created_at: :desc)
                            .first
  end

  def retry_contact_ids
    @retry_contact_ids ||= retryable_delivery_scope
                           &.where(campaign_run: source_run)
                           &.distinct
                           &.pluck(:contact_id) || []
  end

  def retryable_delivery_scope
    retryable = campaign.campaign_deliveries.where(status: RETRYABLE_DELIVERY_STATUSES)
    stale_without_provider_id = campaign.campaign_deliveries.where(
      status: STALE_RETRYABLE_DELIVERY_STATUSES,
      provider_message_id: [nil, '']
    )

    retryable.or(stale_without_provider_id).where.not(campaign_run_id: nil)
  end
end
