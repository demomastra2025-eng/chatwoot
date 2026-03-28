class Campaigns::AnalyticsService
  DELIVERY_STATUSES = %w[pending submitted sent delivered read failed skipped].freeze

  pattr_initialize [:campaign!]

  def call
    {
      campaign_id: campaign.display_id,
      campaign_title: campaign.title,
      inbox_name: campaign.inbox.name,
      audience_size: deliveries.count,
      totals: totals,
      success_rate: success_rate,
      errors: top_errors,
      deliveries: serialized_deliveries
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

  def totals
    DELIVERY_STATUSES.index_with { |status| grouped_statuses[status] || 0 }
  end

  def success_rate
    return 0 if deliveries.count.zero?

    successful = totals['delivered'] + totals['read']
    ((successful.to_f / deliveries.count) * 100).round(1)
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
end
