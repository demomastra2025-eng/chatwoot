class Twilio::OneoffSmsCampaignService < Campaigns::OneoffBaseService
  private

  def supported_inbox_types
    'Twilio SMS'
  end

  def delivery_provider
    'twilio_sms'
  end

  def missing_target_error_message
    'Contact has no phone number'
  end

  def delivery_log_prefix
    'Twilio'
  end

  def target_identifier_for(contact)
    super
  end

  def perform_delivery(contact:, delivery:, target_identifier:)
    content = Liquid::CampaignTemplateService.new(campaign: campaign, contact: contact).call(campaign.message)
    twilio_message = channel.send_message(to: target_identifier, body: content)

    if twilio_message.present?
      delivery.mark_status!(status: :submitted, provider_message_id: twilio_message.sid)
    else
      delivery.mark_status!(status: :failed, error_message: 'Twilio did not return a message id')
    end
  end
end
