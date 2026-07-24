class Whatsapp::SendOnWhatsappService < Base::SendOnChannelService
  MISSING_RECIPIENT_ERROR = 'WhatsApp recipient identifier is missing or unsupported by the provider'.freeze
  BSUID_AUTHENTICATION_TEMPLATE_ERROR = 'WhatsApp authentication templates require a recipient phone number'.freeze
  BLANK_SESSION_MESSAGE_ERROR = Messages::MessageBuilder::BLANK_WHATSAPP_OUTBOUND_ERROR

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
    return fail_bsuid_authentication_template! if bsuid_authentication_template?

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

    message_id = send_template_to_provider(name, namespace, lang_code, processed_parameters)
    handle_template_send_result(message_id, name, lang_code)
  end

  def send_session_message
    return fail_missing_recipient! if recipient_source_id.blank?
    return fail_blank_session_message! if blank_session_message?

    message_id = channel.send_message(recipient_source_id, message)
    message.update!(source_id: message_id) if message_id.present?
  end

  def send_template_to_provider(name, namespace, lang_code, processed_parameters)
    channel.send_template(recipient_source_id, {
                            name: name,
                            namespace: namespace,
                            lang_code: lang_code,
                            parameters: processed_parameters
                          }, message)
  end

  def handle_template_send_result(message_id, name, lang_code)
    return handle_submitted_template(message_id, name, lang_code) if message_id.present?
    return handle_deferred_template if transient_whatsapp_cloud_retry_scheduled?
    return handle_ambiguous_template if ambiguous_whatsapp_cloud_delivery?

    update_campaign_delivery(status: :failed, error_message: 'WhatsApp provider did not return a message id')
  end

  def handle_submitted_template(message_id, name, lang_code)
    message.update!(source_id: message_id)
    update_campaign_delivery(
      status: :submitted,
      provider_message_id: message_id,
      metadata: { template_name: name, template_language: lang_code }
    )
  end

  def handle_deferred_template
    update_campaign_delivery(
      status: :pending,
      metadata: Whatsapp::Providers::WhatsappCloudService.transient_send_retry_metadata(message)
    )
  end

  def handle_ambiguous_template
    update_campaign_delivery(status: :pending, metadata: { delivery_outcome_unknown: true })
  end

  def recipient_source_id
    return @recipient_source_id if defined?(@recipient_source_id)

    contact_inbox = Whatsapp::PreferredContactInboxResolver.new(
      contact: recipient_contact,
      inbox: inbox,
      fallback_contact_inbox: conversation.contact_inbox
    ).perform
    source_id = contact_inbox&.source_id
    @recipient_source_id = Whatsapp::ContactIdentityResolver.phone_source_id(source_id) || cloud_bsuid_source_id(source_id)
  end

  def cloud_bsuid_source_id(source_id)
    return unless channel.provider == 'whatsapp_cloud'

    Whatsapp::ContactIdentityResolver.bsuid_source_id(source_id)
  end

  def bsuid_authentication_template?
    Whatsapp::ContactIdentityResolver.bsuid_source_id(recipient_source_id).present? &&
      template_params.to_h.with_indifferent_access[:category].to_s.casecmp?('AUTHENTICATION')
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

  def transient_whatsapp_cloud_retry_scheduled?
    channel.provider == 'whatsapp_cloud' && Whatsapp::Providers::WhatsappCloudService.transient_send_retry_scheduled?(message.reload)
  end

  def ambiguous_whatsapp_cloud_delivery?
    channel.provider == 'whatsapp_cloud' && Whatsapp::Providers::WhatsappCloudService.delivery_outcome_unknown?(message.reload)
  end

  def blank_session_message?
    message.outgoing_content.blank? && message.attachments.blank?
  end

  def fail_blank_session_message!
    message.update!(status: :failed, external_error: BLANK_SESSION_MESSAGE_ERROR)
    update_campaign_delivery(status: :failed, error_message: BLANK_SESSION_MESSAGE_ERROR)
  end

  def fail_missing_recipient!
    message.update!(status: :failed, external_error: MISSING_RECIPIENT_ERROR)
    update_campaign_delivery(status: :failed, error_message: MISSING_RECIPIENT_ERROR)
  end

  def fail_bsuid_authentication_template!
    message.update!(status: :failed, external_error: BSUID_AUTHENTICATION_TEMPLATE_ERROR)
    update_campaign_delivery(status: :failed, error_message: BSUID_AUTHENTICATION_TEMPLATE_ERROR)
  end

  def campaign_id
    message.additional_attributes&.[]('campaign_id') || conversation.campaign_id
  end

  def campaign_run_id
    message.additional_attributes&.[]('campaign_run_id')
  end
end
