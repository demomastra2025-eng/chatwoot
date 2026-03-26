class Twilio::OneoffSmsCampaignService
  pattr_initialize [:campaign!]

  def perform
    raise "Invalid campaign #{campaign.id}" if campaign.inbox.inbox_type != 'Twilio SMS' || !campaign.one_off?
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

      begin
        twilio_message = channel.send_message(to: contact.phone_number, body: content)

        if twilio_message.present?
          delivery.mark_status!(status: :submitted, provider_message_id: twilio_message.sid)
        else
          delivery.mark_status!(status: :failed, error_message: 'Twilio did not return a message id')
        end
      rescue Twilio::REST::TwilioError, Twilio::REST::RestError => e
        delivery.mark_status!(status: :failed, error_message: e.message)
        Rails.logger.error("[Twilio Campaign #{campaign.id}] Failed to send to #{contact.phone_number}: #{e.message}")
        next
      end
    end
  end

  def ensure_delivery(contact)
    CampaignDelivery.track!(
      campaign: campaign,
      contact: contact,
      target_identifier: contact.phone_number,
      provider: 'twilio_sms',
      status: :pending
    )
  end
end
