class Whatsapp::SendOnWhatsappService < Base::SendOnChannelService
  MISSING_PHONE_RECIPIENT_ERROR = 'WhatsApp recipient phone number is missing; refusing to send to BSUID'.freeze

  private

  def channel_class
    Channel::Whatsapp
  end

  def perform_reply
    should_send_template_message = template_params.present? || !message.conversation.can_reply?
    if should_send_template_message
      send_template_message
    else
      send_session_message
    end
  end

  def send_template_message
    return fail_missing_recipient! if recipient_source_id.blank?

    processor = Whatsapp::TemplateProcessorService.new(
      channel: channel,
      template_params: template_params,
      message: message
    )

    name, namespace, lang_code, processed_parameters = processor.call

    if name.blank?
      message.update!(status: :failed, external_error: 'Template not found or invalid template name')
      update_campaign_delivery(status: :failed, error_message: 'Template not found or invalid template name')
      return
    end

    message_id = channel.send_template(recipient_source_id, {
                                         name: name,
                                         namespace: namespace,
                                         lang_code: lang_code,
                                         parameters: processed_parameters
                                       }, message)

    if message_id.present?
      message.update!(source_id: message_id)
      update_campaign_delivery(
        status: :submitted,
        provider_message_id: message_id,
        metadata: { template_name: name, template_language: lang_code }
      )
    else
      update_campaign_delivery(status: :failed, error_message: 'WhatsApp provider did not return a message id')
    end
  end

  def send_session_message
    return fail_missing_recipient! if recipient_source_id.blank?

    message_id = channel.send_message(recipient_source_id, message)
    message.update!(source_id: message_id) if message_id.present?
  end

  def recipient_source_id
    @recipient_source_id ||= Whatsapp::PreferredContactInboxResolver.new(
      contact: recipient_contact,
      inbox: inbox,
      fallback_contact_inbox: conversation.contact_inbox
    ).perform&.source_id
  end

  def recipient_contact
    conversation.contact_inbox&.contact || conversation.contact
  end

  def template_params
    message.additional_attributes && message.additional_attributes['template_params']
  end

  def update_campaign_delivery(status:, provider_message_id: nil, error_message: nil, metadata: {})
    return if campaign_id.blank?

    deliveries = CampaignDelivery.where(
      campaign_id: campaign_id,
      contact_id: conversation.contact_id,
      inbox_id: inbox.id
    )
    deliveries = deliveries.where(campaign_run_id: campaign_run_id) if campaign_run_id.present?
    delivery = deliveries.order(created_at: :desc).first
    return if delivery.blank?

    delivery.mark_status!(
      status: status,
      provider_message_id: provider_message_id,
      error_message: error_message,
      metadata: metadata
    )
  end

  def fail_missing_recipient!
    message.update!(status: :failed, external_error: MISSING_PHONE_RECIPIENT_ERROR)
    update_campaign_delivery(status: :failed, error_message: MISSING_PHONE_RECIPIENT_ERROR)
  end

  def campaign_id
    message.additional_attributes&.[]('campaign_id') || conversation.campaign_id
  end

  def campaign_run_id
    message.additional_attributes&.[]('campaign_run_id')
  end
end
