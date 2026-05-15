class Campaigns::TestSendService
  DIRECT_SMS_INBOX_TYPES = ['Twilio SMS', 'Sms'].freeze

  pattr_initialize [:campaign!, :contact!, { initiated_by: nil }]

  def perform
    validate!
    Campaigns::TemplateParamsValidator.validate!(inbox: inbox, template_params: campaign.template_params)
    preview = preview_for_contact
    ensure_deliverable!(preview)

    if direct_sms_campaign?
      send_direct_sms!(preview)
    else
      send_conversation_message!(preview)
    end
  end

  private

  delegate :account, :inbox, to: :campaign

  def channel
    inbox.channel
  end

  def validate!
    raise ArgumentError, 'Campaign and contact must belong to the same account' unless contact.account_id == campaign.account_id
    raise ArgumentError, 'Only one-off campaigns can be test-sent' unless campaign.one_off?
    return if Campaign::ONE_OFF_INBOX_TYPES.include?(inbox.inbox_type)

    raise ArgumentError, 'Website trigger campaigns do not support test-send from this tool'
  end

  def preview_for_contact
    Campaigns::PreviewService.new(
      account: account,
      inbox: inbox,
      audience: [],
      message: campaign.message,
      instructions: campaign.instructions,
      text_mode: campaign.text_mode,
      template_params: campaign.template_params,
      scheduled_at: campaign.scheduled_at,
      contact_ids: [contact.id]
    ).call
  end

  def ensure_deliverable!(preview)
    sample = preview_sample(preview)
    raise ArgumentError, 'Test recipient is not deliverable for this campaign inbox' if sample.blank?
    return if sample['deliverable']

    reason = sample['error'].presence || sample['reason'].presence || 'unknown reason'
    raise ArgumentError, "Test recipient is not deliverable: #{reason}"
  end

  def preview_sample(preview)
    sample = Array(preview[:sample_contacts] || preview['sample_contacts']).first
    sample.respond_to?(:with_indifferent_access) ? sample.with_indifferent_access : {}.with_indifferent_access
  end

  def send_direct_sms!(preview)
    target_identifier = preview_target_identifier(preview)
    content = Liquid::CampaignTemplateService.new(campaign: campaign, contact: contact).call(campaign.message)
    provider_message_id = case inbox.inbox_type
                          when 'Twilio SMS'
                            channel.send_message(to: target_identifier, body: content)&.sid
                          when 'Sms'
                            channel.send_text_message(target_identifier, content)
                          end

    raise ArgumentError, 'SMS provider did not return a message id' if provider_message_id.blank?

    result_payload(provider: provider_name, target_identifier: target_identifier, provider_message_id: provider_message_id)
  end

  def send_conversation_message!(preview)
    target_identifier = preview_target_identifier(preview)
    message = Campaigns::OneoffConversationBuilder.new(
      campaign: campaign,
      contact: contact,
      source_id: target_identifier,
      test_send: true,
      conversation_attributes: { outbound_campaign_test_send: true }
    ).perform

    result_payload(
      provider: provider_name,
      target_identifier: target_identifier,
      message_id: message.id,
      conversation_id: message.conversation.display_id
    )
  end

  def result_payload(**attrs)
    {
      campaign_id: campaign.display_id,
      contact_id: contact.id,
      inbox_id: inbox.id,
      inbox_type: inbox.inbox_type,
      test_send: true,
      campaign_status: campaign.reload.campaign_status,
      campaign_runs_count: campaign.campaign_runs.count,
      campaign_deliveries_count: campaign.campaign_deliveries.count
    }.merge(attrs.compact)
  end

  def preview_target_identifier(preview)
    sample = Array(preview[:sample_contacts] || preview['sample_contacts']).first || {}
    sample[:target_identifier] || sample['target_identifier']
  end

  def direct_sms_campaign?
    DIRECT_SMS_INBOX_TYPES.include?(inbox.inbox_type)
  end

  def provider_name
    case inbox.inbox_type
    when 'Twilio SMS'
      'twilio_sms'
    when 'Sms'
      'bandwidth_sms'
    else
      inbox.inbox_type.to_s.underscore
    end
  end
end
