class Whatsapp::SendOnWhatsappService < Base::SendOnChannelService
  MISSING_PHONE_RECIPIENT_ERROR = 'WhatsApp recipient phone number is missing; refusing to send to BSUID'.freeze
  FLOW_REPLY_WINDOW_ERROR = 'WhatsApp Flow messages require an open WhatsApp reply window; use a WhatsApp template Flow button instead.'.freeze
  UNSUPPORTED_FLOW_CHANNEL_ERROR = 'WhatsApp Flow messages are only available for WhatsApp Cloud channels'.freeze
  INVALID_FLOW_MESSAGE_ERROR = 'WhatsApp Flow message is missing required flow parameters'.freeze
  FLOW_MESSAGE_KIND = 'whatsapp_flow'.freeze

  private

  def channel_class
    Channel::Whatsapp
  end

  def perform_reply
    return send_flow_message if flow_message?

    should_send_template_message = template_params.present? || !message.conversation.can_reply?
    if should_send_template_message
      send_template_message
    else
      send_session_message
    end
  end

  def send_flow_message
    return fail_missing_recipient! if recipient_source_id.blank?
    return fail_flow_message!(UNSUPPORTED_FLOW_CHANNEL_ERROR) unless channel.provider == 'whatsapp_cloud'
    return fail_flow_message!(FLOW_REPLY_WINDOW_ERROR) unless message.conversation.can_reply?
    return fail_flow_message!(INVALID_FLOW_MESSAGE_ERROR) unless valid_flow_params?

    message_id = channel.send_flow(recipient_source_id, flow_params, message)
    if message_id.present?
      message.update!(source_id: message_id)
      flow_session&.mark_sent!(message: message, request_payload: flow_params.except('flow_token'))
    end
  end

  def flow_message?
    flow_data['kind'] == FLOW_MESSAGE_KIND
  end

  def flow_data
    @flow_data ||= message.content_attributes.to_h.deep_stringify_keys.fetch('data', {})
  end

  def flow_params
    @flow_params ||= {
      'flow_message_version' => flow_data['flow_message_version'] || '3',
      'flow_id' => flow_data['flow_id'] || flow_data['provider_flow_id'] || flow_session&.flow&.provider_flow_id,
      'flow_name' => flow_data['flow_name'] || flow_session&.flow&.name,
      'flow_json' => flow_data['flow_json'] || flow_session&.flow&.flow_json,
      'flow_cta' => flow_data['flow_cta'],
      'flow_token' => flow_session&.token,
      'flow_action' => flow_data['flow_action'] || 'navigate',
      'flow_action_payload' => flow_data['flow_action_payload'],
      'mode' => flow_data['mode'] || flow_session&.flow&.mode,
      'header_text' => flow_data['header_text'],
      'body_text' => flow_data['body_text'].presence || message.outgoing_content,
      'footer_text' => flow_data['footer_text']
    }.compact
  end

  def valid_flow_params?
    flow_identifier_present? && flow_params['flow_cta'].present? && flow_params['flow_token'].present? && flow_params['body_text'].present?
  end

  def flow_identifier_present?
    flow_params['flow_id'].present? || flow_params['flow_name'].present? || flow_params['flow_json'].present?
  end

  def flow_session
    @flow_session ||= begin
      session_id = flow_data['flow_session_id'] || flow_data['session_id']
      if session_id.present?
        Whatsapp::FlowSession.find_by(id: session_id, account_id: inbox.account_id, inbox_id: inbox.id)
      end
    end
  end

  def fail_flow_message!(error_message)
    message.update!(status: :failed, external_error: error_message)
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

    message_id = send_template_to_provider(name, namespace, lang_code, processed_parameters)
    handle_template_send_result(message_id, name, lang_code)
  rescue ArgumentError => e
    message.update!(status: :failed, external_error: e.message)
    mark_template_flow_sessions_failed!
    update_campaign_delivery(status: :failed, error_message: e.message)
  end

  def send_session_message
    return fail_missing_recipient! if recipient_source_id.blank?

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
    if message_id.present?
      message.update!(source_id: message_id)
      mark_template_flow_sessions_sent!
      update_campaign_delivery(
        status: :submitted,
        provider_message_id: message_id,
        metadata: { template_name: name, template_language: lang_code }
      )
    elsif transient_whatsapp_cloud_retry_scheduled?
      update_campaign_delivery(
        status: :pending,
        metadata: Whatsapp::Providers::WhatsappCloudService.transient_send_retry_metadata(message)
      )
    else
      mark_template_flow_sessions_failed!
      update_campaign_delivery(status: :failed, error_message: 'WhatsApp provider did not return a message id')
    end
  end

  def recipient_source_id
    @recipient_source_id ||= begin
      source_id = Whatsapp::PreferredContactInboxResolver.new(
        contact: recipient_contact,
        inbox: inbox,
        fallback_contact_inbox: conversation.contact_inbox
      ).perform&.source_id

      Whatsapp::ContactIdentityResolver.phone_source_id(source_id)
    end
  end

  def mark_template_flow_sessions_sent!
    template_flow_sessions.each do |session|
      session.mark_sent!(message: message, request_payload: session.request_payload)
    end
  end

  def mark_template_flow_sessions_failed!
    template_flow_sessions.each do |session|
      next if session.status == 'submitted'

      session.update!(status: 'failed')
    end
  end

  def template_flow_sessions
    session_ids = Array(
      message.reload.additional_attributes&.dig('template_params', 'processed_params', 'buttons')
    ).filter_map do |button|
      next unless button.is_a?(Hash) && button['type'].to_s.casecmp('flow').zero?

      button['flow_session_id'] || button[:flow_session_id] || button['session_id'] || button[:session_id]
    end
    return [] if session_ids.blank?

    Whatsapp::FlowSession.where(id: session_ids, account_id: inbox.account_id, inbox_id: inbox.id)
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
