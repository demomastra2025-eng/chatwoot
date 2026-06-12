class Whatsapp::Providers::WhatsappCloudService < Whatsapp::Providers::BaseService # rubocop:disable Metrics/ClassLength
  TRANSIENT_SEND_ERROR_CODES = [1, 131_000].freeze
  TRANSIENT_SEND_RETRY_DELAYS = [30.seconds, 2.minutes, 5.minutes].freeze
  TRANSIENT_SEND_RETRY_COUNT_KEY = 'whatsapp_cloud_send_retry_count'.freeze
  TRANSIENT_SEND_RETRY_ERROR_CODE_KEY = 'whatsapp_cloud_send_retry_error_code'.freeze
  TRANSIENT_SEND_RETRY_ERROR_MESSAGE_KEY = 'whatsapp_cloud_send_retry_error_message'.freeze
  TRANSIENT_SEND_RETRY_NEXT_AT_KEY = 'whatsapp_cloud_send_retry_next_at'.freeze
  TRANSIENT_SEND_RETRY_KEYS = [
    TRANSIENT_SEND_RETRY_COUNT_KEY,
    TRANSIENT_SEND_RETRY_ERROR_CODE_KEY,
    TRANSIENT_SEND_RETRY_ERROR_MESSAGE_KEY,
    TRANSIENT_SEND_RETRY_NEXT_AT_KEY
  ].freeze

  def send_message(phone_number, message)
    @message = message

    if message.attachments.present?
      send_attachment_message(phone_number, message)
    elsif message.content_type == 'input_select'
      send_interactive_text_message(phone_number, message)
    else
      send_text_message(phone_number, message)
    end
  end

  def send_template(phone_number, template_info, message)
    template_body = template_body_parameters(template_info)

    request_body = {
      messaging_product: 'whatsapp',
      recipient_type: 'individual', # Only individual messages supported (not group messages)
      to: phone_number,
      type: 'template',
      template: template_body
    }

    response = HTTParty.post(
      "#{phone_id_path}/messages",
      headers: api_headers,
      query: graph_api_query,
      body: request_body.to_json
    )

    process_response(response, message)
  end

  def process_response(response, message)
    message_id = super
    clear_transient_send_retry_metadata(message) if message_id.present?
    message_id
  end

  def sync_templates
    # ensuring that channels with wrong provider config wouldn't keep trying to sync templates
    whatsapp_channel.mark_message_templates_updated
    templates = fetch_templates
    return false if templates.nil?

    cache_attributes = { message_templates: templates, message_templates_last_updated: Time.current.utc }
    whatsapp_channel.update_columns(cache_attributes) # rubocop:disable Rails/SkipsModelValidations
  end

  def fetch_templates = fetch_whatsapp_templates("#{business_account_path}/message_templates")

  def create_template(request_body)
    HTTParty.post(
      "#{business_account_path}/message_templates",
      headers: api_headers,
      query: graph_api_query,
      body: request_body.to_json,
      timeout: request_timeout
    )
  end

  def delete_template(template_name)
    HTTParty.delete(
      "#{business_account_path}/message_templates",
      headers: api_headers,
      query: graph_api_query(name: template_name),
      timeout: request_timeout
    )
  end

  def fetch_whatsapp_templates(url)
    response = HTTParty.get(
      url,
      headers: api_headers,
      query: graph_api_query,
      timeout: request_timeout
    )
    unless response.success?
      record_provider_authorization_error(response)
      return nil
    end

    next_url = next_url(response)
    data = response['data'] || []

    if next_url.present?
      next_page_templates = fetch_whatsapp_templates(next_url)
      return nil if next_page_templates.nil?

      return data + next_page_templates
    end

    data
  end

  def next_url(response)
    response['paging'] ? response['paging']['next'] : ''
  end

  def validate_provider_config?
    response = HTTParty.get(
      "#{business_account_path}/message_templates",
      headers: api_headers,
      query: graph_api_query,
      timeout: request_timeout
    )
    record_provider_authorization_error(response) unless response.success?
    response.success?
  end

  def api_headers
    { 'Authorization' => "Bearer #{whatsapp_channel.provider_config['api_key']}", 'Content-Type' => 'application/json' }
  end

  def create_csat_template(template_config)
    csat_template_service.create_template(template_config)
  end

  def delete_csat_template(template_name = nil)
    template_name ||= CsatTemplateNameService.csat_template_name(whatsapp_channel.inbox.id)
    csat_template_service.delete_template(template_name)
  end

  def get_template_status(template_name)
    csat_template_service.get_template_status(template_name)
  end

  def media_url(media_id)
    "#{api_base_path}/#{api_version}/#{media_id}"
  end

  private

  def request_timeout = ENV.fetch('WHATSAPP_CLOUD_API_TIMEOUT', 20).to_i

  def handle_error(response, message)
    error = provider_error(response)
    retry_delay = transient_send_retry_delay(error, message)

    return super if retry_delay.blank?

    schedule_transient_send_retry!(message, error, retry_delay)
  end

  def provider_error(response)
    Channel::Whatsapp.normalize_provider_error(response.parsed_response)
  end

  def transient_send_retry_delay(error, message)
    return if message.blank?
    return if message.source_id.present?
    return unless TRANSIENT_SEND_ERROR_CODES.include?(error['code'].to_i)

    TRANSIENT_SEND_RETRY_DELAYS[next_transient_send_retry_count(message) - 1]
  end

  def next_transient_send_retry_count(message)
    message.content_attributes.to_h[TRANSIENT_SEND_RETRY_COUNT_KEY].to_i + 1
  end

  def schedule_transient_send_retry!(message, error, retry_delay)
    retry_count = next_transient_send_retry_count(message)
    retry_at = retry_delay.from_now
    content_attributes = message.content_attributes.to_h.deep_stringify_keys
    content_attributes.delete('external_error')
    content_attributes.merge!(
      TRANSIENT_SEND_RETRY_COUNT_KEY => retry_count,
      TRANSIENT_SEND_RETRY_ERROR_CODE_KEY => error['code'].to_i,
      TRANSIENT_SEND_RETRY_ERROR_MESSAGE_KEY => error['message'],
      TRANSIENT_SEND_RETRY_NEXT_AT_KEY => retry_at.iso8601
    )

    message.update!(status: :sent, content_attributes: content_attributes)
    SendReplyJob.set(wait: retry_delay).perform_later(message.id)

    Rails.logger.warn(
      '[WHATSAPP_CLOUD] transient send error; retry scheduled ' \
      "message_id=#{message.id} code=#{error['code']} retry_count=#{retry_count} retry_at=#{retry_at.iso8601}"
    )
  end

  def clear_transient_send_retry_metadata(message)
    return if message.blank?

    content_attributes = message.content_attributes.to_h.deep_stringify_keys
    updated_attributes = content_attributes.except(*TRANSIENT_SEND_RETRY_KEYS, 'external_error')
    return if updated_attributes == content_attributes

    message.update!(content_attributes: updated_attributes)
  end

  def graph_api_query(extra_params = {})
    extra_params.merge(
      Whatsapp::FacebookApiClient.appsecret_proof_query(whatsapp_channel.provider_config['api_key'])
    )
  end

  def csat_template_service
    @csat_template_service ||= Whatsapp::CsatTemplateService.new(whatsapp_channel)
  end

  def api_base_path
    ENV.fetch('WHATSAPP_CLOUD_BASE_URL', 'https://graph.facebook.com')
  end

  def phone_id_path
    "#{api_base_path}/#{api_version}/#{whatsapp_channel.provider_config['phone_number_id']}"
  end

  def business_account_path
    "#{api_base_path}/#{api_version}/#{whatsapp_channel.provider_config['business_account_id']}"
  end

  def api_version
    @api_version ||= GlobalConfigService.load('WHATSAPP_API_VERSION', 'v22.0')
  end

  def send_text_message(phone_number, message)
    response = HTTParty.post(
      "#{phone_id_path}/messages",
      headers: api_headers,
      query: graph_api_query,
      body: {
        messaging_product: 'whatsapp',
        context: whatsapp_reply_context(message),
        to: phone_number,
        text: { body: message.outgoing_content },
        type: 'text'
      }.to_json
    )

    process_response(response, message)
  end

  def send_attachment_message(phone_number, message)
    attachment = message.attachments.first
    type = %w[image audio video].include?(attachment.file_type) ? attachment.file_type : 'document'
    type_content = { link: attachment.download_url }
    type_content['caption'] = message.outgoing_content unless %w[audio sticker].include?(type)
    type_content['filename'] = attachment.file.filename if type == 'document'
    response = HTTParty.post(
      "#{phone_id_path}/messages",
      headers: api_headers,
      query: graph_api_query,
      body: {
        :messaging_product => 'whatsapp',
        :context => whatsapp_reply_context(message),
        'to' => phone_number,
        'type' => type,
        type.to_s => type_content
      }.to_json
    )

    process_response(response, message)
  end

  def error_message(response)
    # https://developers.facebook.com/docs/whatsapp/cloud-api/support/error-codes/#sample-response
    response.parsed_response&.dig('error', 'message')
  end

  def template_body_parameters(template_info)
    template_body = {
      name: template_info[:name],
      language: {
        policy: 'deterministic',
        code: template_info[:lang_code]
      }
    }

    # Enhanced template parameters structure
    # Note: Legacy format support (simple parameter arrays) has been removed
    # in favor of the enhanced component-based structure that supports
    # headers, buttons, and authentication templates.
    #
    # Expected payload format from frontend:
    # {
    #   processed_params: {
    #     body: { '1': 'John', '2': '123 Main St' },
    #     header: {
    #       media_url: 'https://...',
    #       media_type: 'image',
    #       media_name: 'filename.pdf' # Optional, for document templates only
    #     },
    #     buttons: [{ type: 'url', parameter: 'otp123456' }]
    #   }
    # }
    # This gets transformed into WhatsApp API component format:
    # [
    #   { type: 'body', parameters: [...] },
    #   { type: 'header', parameters: [...] },
    #   { type: 'button', sub_type: 'url', parameters: [...] }
    # ]
    template_body[:components] = template_info[:parameters] || []

    template_body
  end

  def whatsapp_reply_context(message)
    reply_to = message.content_attributes[:in_reply_to_external_id]
    return nil if reply_to.blank?

    {
      message_id: reply_to
    }
  end

  def send_interactive_text_message(phone_number, message)
    payload = create_payload_based_on_items(message)

    response = HTTParty.post(
      "#{phone_id_path}/messages",
      headers: api_headers,
      query: graph_api_query,
      body: {
        messaging_product: 'whatsapp',
        to: phone_number,
        interactive: payload,
        type: 'interactive'
      }.to_json
    )

    process_response(response, message)
  end
end

Whatsapp::Providers::WhatsappCloudService.include_mod_with('Whatsapp::Providers::WhatsappCloudService')
