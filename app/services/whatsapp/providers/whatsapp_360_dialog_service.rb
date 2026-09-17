class Whatsapp::Providers::Whatsapp360DialogService < Whatsapp::Providers::BaseService
  DELIVERY_OUTCOME_UNKNOWN_KEY = 'whatsapp_360_delivery_outcome_unknown'.freeze

  def self.delivery_outcome_unknown?(message)
    ActiveModel::Type::Boolean.new.cast(message&.content_attributes.to_h.deep_stringify_keys[DELIVERY_OUTCOME_UNKNOWN_KEY])
  end

  def send_message(phone_number, message)
    @message = message
    return if suppress_ambiguous_delivery_retry?(message)

    if message.attachments.present?
      send_attachment_message(phone_number, message)
    elsif message.content_type == 'input_select'
      send_interactive_text_message(phone_number, message)
    else
      send_text_message(phone_number, message)
    end
  end

  def send_template(phone_number, template_info, message)
    return if suppress_ambiguous_delivery_retry?(message)

    submit_message(
      {
        to: phone_number,
        template: template_body_parameters(template_info),
        type: 'template'
      },
      message
    )
  end

  def sync_templates
    # ensuring that channels with wrong provider config wouldn't keep trying to sync templates
    whatsapp_channel.mark_message_templates_updated
    response = HTTParty.get("#{api_base_path}/configs/templates", headers: api_headers)
    return false unless response.success?

    whatsapp_channel.update!(
      message_templates: Array(response['waba_templates']),
      message_templates_last_updated: Time.current.utc
    )
  end

  def validate_provider_config?
    response = HTTParty.post(
      "#{api_base_path}/configs/webhook",
      headers: { 'D360-API-KEY': whatsapp_channel.provider_config['api_key'], 'Content-Type': 'application/json' },
      body: {
        url: "#{ENV.fetch('FRONTEND_URL', nil)}/webhooks/whatsapp/#{whatsapp_channel.phone_number}"
      }.to_json
    )
    response.success?
  end

  def api_headers
    { 'D360-API-KEY' => whatsapp_channel.provider_config['api_key'], 'Content-Type' => 'application/json' }
  end

  def media_url(media_id)
    "#{api_base_path}/media/#{media_id}"
  end

  private

  def api_base_path
    # provide the environment variable when testing against sandbox : 'https://waba-sandbox.360dialog.io/v1'
    ENV.fetch('360DIALOG_BASE_URL', 'https://waba.360dialog.io/v1')
  end

  def request_timeout
    ENV.fetch('WHATSAPP_360_API_TIMEOUT', 20).to_i
  end

  def send_text_message(phone_number, message)
    submit_message(
      {
        to: phone_number,
        text: { body: message.outgoing_content },
        type: 'text'
      },
      message
    )
  end

  def send_attachment_message(phone_number, message)
    attachment = message.attachments.first
    type = %w[image audio video].include?(attachment.file_type) ? attachment.file_type : 'document'
    type_content = {
      'link': attachment.download_url
    }
    type_content['caption'] = message.outgoing_content unless %w[audio sticker].include?(type)
    type_content['filename'] = attachment.file.filename if type == 'document'

    submit_message(
      {
        'to' => phone_number,
        'type' => type,
        type.to_s => type_content
      },
      message
    )
  end

  def error_message(response)
    # {"meta": {"success": false, "http_code": 400, "developer_message": "errro-message", "360dialog_trace_id": "someid"}}
    response.parsed_response.dig('meta', 'developer_message')
  end

  def template_body_parameters(template_info)
    {
      name: template_info[:name],
      namespace: template_info[:namespace],
      language: {
        policy: 'deterministic',
        code: template_info[:lang_code]
      },
      components: template_info[:parameters]
    }
  end

  def send_interactive_text_message(phone_number, message)
    payload = create_payload_based_on_items(message)

    submit_message(
      {
        to: phone_number,
        interactive: payload,
        type: 'interactive'
      },
      message
    )
  end

  def submit_message(body, message)
    response = HTTParty.post(
      "#{api_base_path}/messages",
      headers: api_headers,
      body: body.to_json,
      timeout: request_timeout
    )

    process_response(response, message)
  rescue Timeout::Error, EOFError, Errno::ECONNRESET, Errno::ETIMEDOUT,
         Whatsapp::Providers::BaseService::DeliveryAcknowledgementMissingError => e
    record_unknown_delivery_outcome!(message, e)
    nil
  end

  def record_unknown_delivery_outcome!(message, error)
    content_attributes = message.content_attributes.to_h.deep_stringify_keys.except('external_error')
    content_attributes.merge!(
      DELIVERY_OUTCOME_UNKNOWN_KEY => true,
      'whatsapp_360_delivery_outcome_unknown_at' => Time.current.iso8601,
      'whatsapp_360_delivery_outcome_error_class' => error.class.name
    )
    message.update!(status: :sent, external_error: nil, content_attributes: content_attributes)
    Rails.logger.warn("[WHATSAPP_360] delivery outcome unknown; automatic retry suppressed message_id=#{message.id} error=#{error.class}")
  end

  def suppress_ambiguous_delivery_retry?(message)
    return false unless self.class.delivery_outcome_unknown?(message)

    Rails.logger.warn("[WHATSAPP_360] duplicate send suppressed after unknown delivery outcome message_id=#{message.id}")
    true
  end
end
