class Sms::OneoffSmsCampaignService
  pattr_initialize [:campaign!]

  def perform
    raise "Invalid campaign #{campaign.id}" if campaign.inbox.inbox_type != 'Sms' || !campaign.one_off?
    raise 'Completed Campaign' if campaign.completed?

    # marks campaign completed so that other jobs won't pick it up
    campaign.completed!

    audience_label_ids = campaign.audience.select { |audience| audience['type'] == 'Label' }.pluck('id')
    audience_labels = campaign.account.labels.where(id: audience_label_ids).pluck(:title)
    process_audience(audience_labels)
  end

  private

  delegate :inbox, to: :campaign
  delegate :channel, to: :inbox

  def process_audience(audience_labels)
    campaign.account.contacts.tagged_with(audience_labels, any: true).each do |contact|
      delivery = ensure_delivery(contact)

      if contact.phone_number.blank?
        delivery.mark_status!(status: :skipped, error_message: 'Contact has no phone number')
        next
      end

      content = Liquid::CampaignTemplateService.new(campaign: campaign, contact: contact).call(campaign.message)
      send_message(delivery: delivery, to: contact.phone_number, content: content)
    end
  end

  def send_message(delivery:, to:, content:)
    provider_message_id = channel.send_text_message(to, content)

    if provider_message_id.present?
      delivery.mark_status!(status: :submitted, provider_message_id: provider_message_id)
    else
      delivery.mark_status!(status: :failed, error_message: 'SMS provider did not return a message id')
    end
  rescue StandardError => e
    delivery.mark_status!(status: :failed, error_message: e.message)
    Rails.logger.error("[SMS Campaign #{campaign.id}] Failed to send to #{to}: #{e.message}")
  end

  def ensure_delivery(contact)
    CampaignDelivery.track!(
      campaign: campaign,
      contact: contact,
      target_identifier: contact.phone_number,
      provider: 'bandwidth_sms',
      status: :pending
    )
  end
end
