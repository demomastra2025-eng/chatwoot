class Campaigns::OneoffBaseService
  pattr_initialize [:campaign!, { campaign_run: nil, contact_ids: nil, allow_terminal_retry: false }]

  def perform
    validate_campaign!
    mark_campaign_running!
    current_campaign_run.start!(total_count: audience_size, metadata: run_metadata)

    audience_contacts.find_each(batch_size: 200) do |contact|
      break if cancellation_requested?

      process_contact(contact)
    end

    return finalize_cancelled_execution! if cancellation_requested?

    finalize_campaign_run!
    finalize_campaign_status!
  rescue StandardError => e
    existing_campaign_run = @current_campaign_run || campaign_run
    unless existing_campaign_run&.failed? || existing_campaign_run&.cancelled?
      existing_campaign_run&.fail!(
        e.message,
        audience_size: (@audience_size || existing_campaign_run.total_count)
      )
    end
    fail_campaign_execution!
    raise
  end

  private

  delegate :inbox, to: :campaign
  delegate :channel, to: :inbox

  def validate_campaign!
    raise "Invalid campaign #{campaign.id}" unless valid_campaign?
    raise 'Campaign already running' if campaign.running? && !campaign_run_owns_execution?
    raise 'Cancelled Campaign' if campaign.cancelled? && !allow_terminal_retry

    unless allow_terminal_retry
      raise 'Completed Campaign' if campaign.completed?
      raise 'Failed Campaign' if campaign.failed?
    end

    validate_campaign_specific!
  end

  def valid_campaign?
    campaign.one_off? && Array.wrap(supported_inbox_types).include?(inbox.inbox_type)
  end

  def validate_campaign_specific!; end

  def process_contact(contact)
    target_identifier = target_identifier_for(contact)
    delivery = ensure_delivery(contact, target_identifier)

    if target_identifier.blank?
      delivery.mark_status!(status: :skipped, error_message: missing_target_error_message)
      return
    end

    skip_reason = skip_contact_reason(contact)
    if skip_reason.present?
      delivery.mark_status!(status: :skipped, error_message: skip_reason)
      log_skip(contact, skip_reason)
      return
    end

    perform_delivery(contact: contact, delivery: delivery, target_identifier: target_identifier)
  rescue StandardError => e
    delivery&.mark_status!(status: :failed, error_message: e.message)
    log_delivery_failure(contact, e)
  end

  def audience_contacts
    @audience_contacts ||= begin
      contacts = Campaigns::AudienceResolver.new(
        account: campaign.account,
        audience: campaign.audience
      ).contacts

      contact_ids.present? ? contacts.where(id: contact_ids) : contacts
    end
  end

  def audience_size
    @audience_size ||= audience_contacts.count
  end

  def ensure_delivery(contact, target_identifier)
    CampaignDelivery.track!(
      campaign: campaign,
      campaign_run: current_campaign_run,
      contact: contact,
      target_identifier: target_identifier,
      provider: delivery_provider,
      status: :pending
    )
  end

  def target_identifier_for(contact)
    Campaigns::TargetResolver.new(inbox: inbox, contact: contact).resolve
  end

  def missing_target_error_message
    'Contact has no deliverable target for this inbox'
  end

  def skip_contact_reason(_contact)
    nil
  end

  def log_skip(_contact, _reason); end

  def log_delivery_failure(contact, error)
    Rails.logger.error("[#{delivery_log_prefix} Campaign #{campaign.id}] Failed to send to #{target_identifier_for(contact)}: #{error.message}")
  end

  def mark_campaign_running!
    campaign.with_lock do
      campaign.reload
      if campaign.running?
        raise 'Campaign already running' unless campaign_run_owns_execution?

        return
      end

      campaign.running! if allow_terminal_retry || campaign.active?
    end
  end

  def current_campaign_run
    @current_campaign_run ||= campaign_run || build_campaign_run
  end

  def build_campaign_run
    campaign.campaign_runs.create!(
      account: campaign.account,
      inbox: campaign.inbox,
      metadata: {
        inbox_type: inbox.inbox_type,
        campaign_type: campaign.campaign_type,
        provider: delivery_provider
      }.compact
    )
  end

  def finalize_campaign_run!
    current_campaign_run.complete_from_deliveries!(audience_size: audience_size)
  end

  def finalize_cancelled_execution!
    current_campaign_run.cancel!(audience_size: audience_size) unless current_campaign_run.cancelled?
    campaign.cancelled! unless campaign.cancelled?
  end

  def run_metadata
    {
      provider: delivery_provider
    }.compact
  end

  def finalize_campaign_status!
    campaign.reload
    latest_run = current_campaign_run.reload

    if latest_run.successful_count.positive?
      campaign.completed!
    else
      campaign.failed!
    end
  end

  def cancellation_requested?
    campaign.reload.cancelled? || current_campaign_run.reload.cancelled?
  end

  def fail_campaign_execution!
    campaign.with_lock do
      campaign.reload
      campaign.failed! if campaign.active? || campaign.running?
    end
  end

  def campaign_run_owns_execution?
    campaign_run.present? &&
      campaign_run.campaign_id == campaign.id &&
      campaign_run.account_id == campaign.account_id
  end
end
