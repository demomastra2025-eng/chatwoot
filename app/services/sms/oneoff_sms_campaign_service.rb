class Sms::OneoffSmsCampaignService < Campaigns::OneoffBaseService
  private

  def supported_inbox_types
    'Sms'
  end

  def delivery_provider
    'bandwidth_sms'
  end

  def missing_target_error_message
    'Contact has no phone number'
  end

  def delivery_log_prefix
    'SMS'
  end

  def perform_delivery(contact:, delivery:, target_identifier:)
    content = Liquid::CampaignTemplateService.new(campaign: campaign, contact: contact).call(campaign.message)
    provider_message_id = channel.send_text_message(target_identifier, content)

    if provider_message_id.present?
      delivery.mark_status!(status: :submitted, provider_message_id: provider_message_id)
    else
      delivery.mark_status!(status: :failed, error_message: 'SMS provider did not return a message id')
    end
  end
end
