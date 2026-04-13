class Campaigns::AnalyticsService
  DELIVERY_STATUSES = %w[pending submitted sent delivered read failed skipped].freeze

  pattr_initialize [:campaign!]

  def call
    {
      campaign_id: campaign.display_id,
      campaign_title: campaign.title,
      campaign_status: campaign.campaign_status,
      inbox_name: campaign.inbox.name,
      audience_size: audience_size,
      deliveries_count: processed_contacts_count,
      processed_contacts_count: processed_contacts_count,
      delivery_attempts_count: delivery_attempts_count,
      not_sent_count: not_sent_count,
      coverage_rate: coverage_rate,
      latest_run: serialized_run(latest_run),
      recent_runs: serialized_runs,
      totals: totals,
      success_rate: success_rate,
      errors: top_errors,
      deliveries: serialized_deliveries,
      not_sent_contacts: serialized_not_sent_contacts
    }
  end

  private

  def deliveries
    @deliveries ||= campaign.campaign_deliveries.includes(:contact)
  end

  def ordered_deliveries
    deliveries.order(updated_at: :desc)
  end

  def grouped_statuses
    @grouped_statuses ||= deliveries.reorder(nil).group(:status).count.transform_keys do |key|
      CampaignDelivery.statuses.key(key) || key.to_s
    end
  end

  def audience_contacts
    @audience_contacts ||=
      if campaign.audience.present?
        Campaigns::AudienceResolver.new(
          account: campaign.account,
          audience: campaign.audience
        ).contacts
      else
        campaign.account.contacts.where(
          id: deliveries.reorder(nil).select(:contact_id)
        ).distinct
      end
  end

  def audience_size
    @audience_size ||= audience_contacts.count
  end

  def not_sent_contacts
    @not_sent_contacts ||= audience_contacts.where.not(
      id: deliveries.reorder(nil).select(:contact_id)
    )
  end

  def not_sent_count
    @not_sent_count ||= not_sent_contacts.count
  end

  def coverage_rate
    return 0 if audience_size.zero?

    ((processed_contacts_count.to_f / audience_size) * 100).round(1)
  end

  def totals
    DELIVERY_STATUSES.index_with { |status| grouped_statuses[status] || 0 }
  end

  def success_rate
    return 0 if delivery_attempts_count.zero?

    successful = totals['delivered'] + totals['read']
    ((successful.to_f / delivery_attempts_count) * 100).round(1)
  end

  def top_errors
    deliveries.reorder(nil)
              .where.not(error_message: [nil, ''])
              .group(:error_message)
              .order(Arel.sql('COUNT(*) DESC'))
              .count
              .first(5)
              .map { |message, count| { message: message, count: count } }
  end

  def serialized_deliveries
    ordered_deliveries.limit(100).map do |delivery|
      {
        id: delivery.id,
        status: delivery.status,
        provider: delivery.provider,
        target_identifier: delivery.target_identifier,
        provider_message_id: delivery.provider_message_id,
        error_message: delivery.error_message,
        updated_at: delivery.updated_at.to_i,
        last_status_at: delivery.last_status_at&.to_i,
        contact: {
          id: delivery.contact_id,
          name: delivery.contact.name,
          phone_number: delivery.contact.phone_number
        }
      }
    end
  end

  def serialized_not_sent_contacts
    not_sent_contacts.limit(100).map do |contact|
      {
        id: contact.id,
        name: contact.name,
        phone_number: contact.phone_number,
        email: contact.email
      }
    end
  end

  def campaign_runs
    @campaign_runs ||= campaign.campaign_runs.order(created_at: :desc)
  end

  def latest_run
    @latest_run ||= campaign_runs.first
  end

  def processed_contacts_count
    @processed_contacts_count ||= deliveries.reorder(nil).distinct.count(:contact_id)
  end

  def delivery_attempts_count
    @delivery_attempts_count ||= deliveries.count
  end

  def serialized_runs
    campaign_runs.limit(10).map { |run| serialized_run(run) }
  end

  def serialized_run(run)
    return if run.blank?

    {
      id: run.id,
      status: run.status,
      provider: run.metadata&.[]('provider'),
      inbox_type: run.metadata&.[]('inbox_type'),
      retry_source_run_id: run.metadata&.[]('retry_source_run_id'),
      retry_contacts_count: run.metadata&.[]('retry_contacts_count'),
      restart_run: run.metadata&.[]('restart_run'),
      resume_run: run.metadata&.[]('resume_run'),
      total_count: run.total_count,
      processed_count: run.processed_count,
      successful_count: run.successful_count,
      failed_count: run.failed_count,
      skipped_count: run.skipped_count,
      progress_percentage: run.progress_percentage,
      duration_seconds: run_duration_seconds(run),
      resumable_contacts_count: resumable_contacts_count(run),
      error_message: run.error_message,
      started_at: run.started_at&.to_i,
      completed_at: run.completed_at&.to_i,
      created_at: run.created_at.to_i
    }
  end

  def run_duration_seconds(run)
    return unless run.started_at && run.completed_at

    (run.completed_at - run.started_at).round
  end

  def resumable_contacts_count(run)
    return 0 unless %w[failed cancelled].include?(run.status)

    [run.total_count.to_i - run.processed_count.to_i, 0].max
  end
end
