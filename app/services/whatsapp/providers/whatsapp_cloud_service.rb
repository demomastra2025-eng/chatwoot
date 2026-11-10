class Whatsapp::Providers::WhatsappCloudService < Whatsapp::Providers::BaseService # rubocop:disable Metrics/ClassLength
  TRANSIENT_SEND_ERROR_CODES = [1, 2, 131_000, 131_016, 133_004].freeze
  THROTTLED_SEND_ERROR_CODES = [4, 17, 341, 80_007, 130_429, 131_056].freeze
  TRANSIENT_SEND_RETRY_DELAYS = [15.seconds, 1.minute, 3.minutes].freeze
  THROTTLED_SEND_RETRY_DELAYS = [1.minute, 3.minutes, 10.minutes, 30.minutes].freeze
  TRANSIENT_SEND_RETRY_COUNT_KEY = 'whatsapp_cloud_send_retry_count'.freeze
  TRANSIENT_SEND_RETRY_ERROR_CODE_KEY = 'whatsapp_cloud_send_retry_error_code'.freeze
  TRANSIENT_SEND_RETRY_ERROR_MESSAGE_KEY = 'whatsapp_cloud_send_retry_error_message'.freeze
  TRANSIENT_SEND_RETRY_NEXT_AT_KEY = 'whatsapp_cloud_send_retry_next_at'.freeze
  DELIVERY_OUTCOME_UNKNOWN_KEY = 'whatsapp_cloud_delivery_outcome_unknown'.freeze
  DELIVERY_OUTCOME_UNKNOWN_KEYS = [
    DELIVERY_OUTCOME_UNKNOWN_KEY,
    'whatsapp_cloud_delivery_outcome_unknown_at',
    'whatsapp_cloud_delivery_outcome_error_class'
  ].freeze
  COEXISTENCE_THROUGHPUT_LIMIT = 20
  COEXISTENCE_THROTTLE_KEY = 'whatsapp_cloud_coexistence_throttled'.freeze
  TRANSIENT_SEND_RETRY_KEYS = [
    TRANSIENT_SEND_RETRY_COUNT_KEY,
    TRANSIENT_SEND_RETRY_ERROR_CODE_KEY,
    TRANSIENT_SEND_RETRY_ERROR_MESSAGE_KEY,
    TRANSIENT_SEND_RETRY_NEXT_AT_KEY
  ].freeze

  def self.transient_send_retry_scheduled?(message)
    return false if message.blank?

    content_attributes = message.content_attributes.to_h.deep_stringify_keys
    retry_queued = content_attributes[TRANSIENT_SEND_RETRY_COUNT_KEY].to_i.positive? || content_attributes[COEXISTENCE_THROTTLE_KEY]
    message.sent? && message.source_id.blank? && retry_queued &&
      content_attributes[TRANSIENT_SEND_RETRY_NEXT_AT_KEY].present?
  end

  def self.transient_send_retry_metadata(message)
    message.content_attributes.to_h.deep_stringify_keys.slice(*TRANSIENT_SEND_RETRY_KEYS, COEXISTENCE_THROTTLE_KEY)
  end

  def self.delivery_outcome_unknown?(message)
    ActiveModel::Type::Boolean.new.cast(message&.content_attributes.to_h.deep_stringify_keys[DELIVERY_OUTCOME_UNKNOWN_KEY])
  end

  def send_message(phone_number, message)
    @message = message
    return if suppress_ambiguous_delivery_retry?(message)
    return if defer_for_coexistence_throughput?(message)

    if rich_message_payload.present?
      send_rich_message(phone_number, message)
    elsif message.attachments.present?
      send_attachment_message(phone_number, message)
    elsif message.content_type == 'input_select'
      send_interactive_text_message(phone_number, message)
    else
      send_text_message(phone_number, message)
    end
  end

  def send_template(phone_number, template_info, message)
    return if suppress_ambiguous_delivery_retry?(message)
    return if defer_for_coexistence_throughput?(message)

    template_body = template_body_parameters(template_info)
    recipient_payload = outbound_recipient_payload(phone_number)

    request_body = {
      messaging_product: 'whatsapp',
      recipient_type: 'individual', # Only individual messages supported (not group messages)
      **recipient_payload,
      type: 'template',
      template: template_body
    }

    post_message(request_body, message)
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

    whatsapp_channel.update_message_templates_cache!(templates)
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

  def upload_business_public_key(public_key_pem)
    response = HTTParty.post(
      "#{phone_id_path}/whatsapp_business_encryption",
      headers: {
        'Authorization' => "Bearer #{whatsapp_channel.provider_config['api_key']}",
        'Content-Type' => 'application/x-www-form-urlencoded'
      },
      query: graph_api_query,
      body: URI.encode_www_form(business_public_key: public_key_pem.to_s),
      timeout: request_timeout
    )
    record_provider_authorization_error(response) unless response.success?
    response
  end

  def business_encryption_status
    response = HTTParty.get(
      "#{phone_id_path}/whatsapp_business_encryption",
      headers: api_headers,
      query: graph_api_query,
      timeout: request_timeout
    )
    record_provider_authorization_error(response) unless response.success?
    response
  end

  FLOW_LIST_FIELDS = 'id,name,status,categories,validation_errors,json_version,data_api_version,endpoint_uri'.freeze

  def list_flows(url = nil)
    query = url.present? ? graph_api_query : graph_api_query(fields: FLOW_LIST_FIELDS, limit: 100)
    response = HTTParty.get(
      url.presence || "#{business_account_path}/flows",
      headers: api_headers,
      query: query,
      timeout: request_timeout
    )
    record_provider_authorization_error(response) unless response.success?
    response
  end

  def fetch_all_flows(max_pages: 20)
    items = []
    current_url = nil
    max_pages.times do
      response = list_flows(current_url)
      return { success: false, response: response } unless response.success?

      items.concat(Array(response.parsed_response.to_h['data']))
      current_url = next_url(response)
      break if current_url.blank?
    end
    { success: true, data: items }
  end

  def create_flow(name:, categories:, endpoint_uri: nil)
    body = { name: name, categories: Array(categories) }
    body[:endpoint_uri] = endpoint_uri if endpoint_uri.present?
    response = HTTParty.post(
      "#{business_account_path}/flows",
      headers: api_headers,
      query: graph_api_query,
      body: body.to_json,
      timeout: request_timeout
    )
    record_provider_authorization_error(response) unless response.success?
    response
  end

  def upload_flow_json(flow_id, flow_json_string)
    Tempfile.create(['flow', '.json']) do |file|
      file.write(flow_json_string.to_s)
      file.flush
      file.rewind
      post_flow_json_asset(flow_id, file)
    end
  end

  def publish_flow(flow_id)
    response = HTTParty.post(
      "#{api_base_path}/#{api_version}/#{flow_id}/publish",
      headers: api_headers,
      query: graph_api_query,
      timeout: request_timeout
    )
    record_provider_authorization_error(response) unless response.success?
    response
  end

  def deprecate_flow(flow_id)
    response = HTTParty.post(
      "#{api_base_path}/#{api_version}/#{flow_id}/deprecate",
      headers: api_headers,
      query: graph_api_query,
      timeout: request_timeout
    )
    record_provider_authorization_error(response) unless response.success?
    response
  end

  def delete_flow(flow_id)
    response = HTTParty.delete(
      "#{api_base_path}/#{api_version}/#{flow_id}",
      headers: api_headers,
      query: graph_api_query,
      timeout: request_timeout
    )
    record_provider_authorization_error(response) unless response.success?
    response
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

  def mark_message_read(message_id)
    response = HTTParty.post(
      "#{phone_id_path}/messages",
      headers: api_headers,
      query: graph_api_query,
      body: {
        messaging_product: 'whatsapp',
        status: 'read',
        message_id: message_id
      }.to_json,
      timeout: request_timeout
    )
    record_provider_authorization_error(response) unless response.success?
    response.success?
  end

  def send_typing_indicator(message_id)
    return false if message_id.blank?

    response = HTTParty.post(
      "#{phone_id_path}/messages",
      headers: api_headers,
      query: graph_api_query,
      body: {
        messaging_product: 'whatsapp',
        status: 'read',
        message_id: message_id,
        typing_indicator: { type: 'text' }
      }.to_json,
      timeout: request_timeout
    )
    record_provider_authorization_error(response) unless response.success?
    response.success?
  end

  def send_reaction(phone_number, target_message_id, emoji, conversation: nil)
    built_payload = Whatsapp::OutboundRichMessageBuilder.new(
      payload: {
        type: 'reaction',
        reaction: {
          message_id: target_message_id.to_s,
          emoji: emoji.to_s
        }
      },
      conversation: conversation
    ).build
    body = outbound_message_body(phone_number, built_payload[:type], built_payload[:content])
    response = HTTParty.post(
      "#{phone_id_path}/messages",
      headers: api_headers,
      query: graph_api_query,
      body: body.to_json,
      timeout: request_timeout
    )
    parsed = response.parsed_response.to_h
    return Array(parsed['messages']).first.to_h['id'].presence if response.success? && parsed['error'].blank?

    record_provider_authorization_error(response)
    raise StandardError, error_message(response).presence || 'WhatsApp reaction request failed'
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

    error_code = error['code'].to_i
    retry_count = next_transient_send_retry_count(message)

    return TRANSIENT_SEND_RETRY_DELAYS[retry_count - 1] if TRANSIENT_SEND_ERROR_CODES.include?(error_code)

    THROTTLED_SEND_RETRY_DELAYS[retry_count - 1] if THROTTLED_SEND_ERROR_CODES.include?(error_code)
  end

  def next_transient_send_retry_count(message)
    message.content_attributes.to_h.deep_stringify_keys[TRANSIENT_SEND_RETRY_COUNT_KEY].to_i + 1
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
    updated_attributes = content_attributes.except(
      *TRANSIENT_SEND_RETRY_KEYS, *DELIVERY_OUTCOME_UNKNOWN_KEYS, COEXISTENCE_THROTTLE_KEY, 'external_error'
    )
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
    @api_version ||= GlobalConfigService.load('WHATSAPP_API_VERSION', 'v25.0')
  end

  def send_rich_message(phone_number, message)
    built_payload = Whatsapp::OutboundRichMessageBuilder.new(
      payload: enriched_rich_message_payload(message),
      conversation: message.conversation
    ).build
    body = outbound_message_body(
      phone_number,
      built_payload[:type],
      built_payload[:content],
      context: whatsapp_reply_context(message)
    )

    post_message(body, message)
  end

  def rich_message_payload
    @message.content_attributes.to_h.with_indifferent_access[:whatsapp_payload]
  end

  def post_flow_json_asset(flow_id, file)
    response = HTTParty.post(
      "#{api_base_path}/#{api_version}/#{flow_id}/assets",
      headers: { 'Authorization' => "Bearer #{whatsapp_channel.provider_config['api_key']}" },
      query: graph_api_query,
      multipart: true,
      stream_body: false,
      body: { name: 'flow.json', asset_type: 'FLOW_JSON', file: file },
      timeout: request_timeout
    )
    record_provider_authorization_error(response) unless response.success?
    response
  end

  def enriched_rich_message_payload(message)
    payload = rich_message_payload.to_h.deep_dup.with_indifferent_access
    return payload unless payload[:type].to_s == 'flow'

    flow = payload[:flow].to_h.with_indifferent_access
    cached_flow = Array(whatsapp_channel.provider_config.to_h.dig('whatsapp_flows', 'flows')).find do |item|
      item['id'].to_s == flow[:flow_id].to_s
    end.to_h
    if cached_flow['kind'].to_s == 'clinic_intake'
      flow[:flow_action] = 'navigate'
      flow[:flow_action_payload] = { 'screen' => 'INTAKE_STEP' } if flow.dig(:flow_action_payload, :screen).blank?
    end
    if flow[:flow_token].blank? || flow[:flow_token].to_s == 'unused'
      flow[:flow_token] = generate_outbound_flow_token(flow[:flow_id], message)
    end
    payload[:flow] = flow
    payload
  end

  def generate_outbound_flow_token(flow_id, message)
    cached_flow = Array(whatsapp_channel.provider_config.to_h.dig('whatsapp_flows', 'flows')).find do |item|
      item['id'].to_s == flow_id.to_s
    end.to_h
    Whatsapp::Flows::TokenService.generate_flow_token(
      channel: whatsapp_channel,
      kind: cached_flow['kind'].presence || 'booking',
      conversation_id: message.conversation_id,
      contact_id: message.conversation&.contact_id,
      locale: cached_flow['locale']
    )
  end

  def send_text_message(phone_number, message)
    body = outbound_message_body(
      phone_number, 'text', { body: message.outgoing_content }, context: whatsapp_reply_context(message)
    )
    post_message(body, message)
  end

  def send_attachment_message(phone_number, message)
    attachment = message.attachments.first
    type = %w[image audio video].include?(attachment.file_type) ? attachment.file_type : 'document'
    type_content = { link: attachment.download_url }
    type_content['caption'] = message.outgoing_content unless %w[audio sticker].include?(type)
    type_content['filename'] = attachment.file.filename if type == 'document'
    body = outbound_message_body(phone_number, type, type_content, context: whatsapp_reply_context(message))
    post_message(body, message)
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

  def outbound_message_body(phone_number, type, content, context: nil)
    body = {
      messaging_product: 'whatsapp',
      recipient_type: 'individual',
      context: context
    }.compact.merge(outbound_recipient_payload(phone_number))
    body[type] = content
    body[:type] = type
    body
  end

  def outbound_recipient_payload(identifier)
    bsuid = Whatsapp::ContactIdentityResolver.bsuid_source_id(identifier)
    return { recipient: bsuid } if bsuid.present?

    { to: identifier }
  end

  def send_interactive_text_message(phone_number, message)
    payload = create_payload_based_on_items(message)
    body = outbound_message_body(phone_number, 'interactive', payload)

    post_message(body, message)
  end

  def post_message(body, message)
    response = HTTParty.post(
      "#{phone_id_path}/messages",
      headers: api_headers,
      query: graph_api_query,
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
    content_attributes = message.content_attributes.to_h.deep_stringify_keys.except(*TRANSIENT_SEND_RETRY_KEYS, 'external_error')
    content_attributes.merge!(
      DELIVERY_OUTCOME_UNKNOWN_KEY => true,
      'whatsapp_cloud_delivery_outcome_unknown_at' => Time.current.iso8601,
      'whatsapp_cloud_delivery_outcome_error_class' => error.class.name
    )
    message.update!(status: :sent, external_error: nil, content_attributes: content_attributes)
    Rails.logger.warn("[WHATSAPP_CLOUD] delivery outcome unknown; automatic retry suppressed message_id=#{message.id} error=#{error.class}")
  end

  def suppress_ambiguous_delivery_retry?(message)
    return false unless self.class.delivery_outcome_unknown?(message)

    Rails.logger.warn("[WHATSAPP_CLOUD] duplicate send suppressed after unknown delivery outcome message_id=#{message.id}")
    true
  end

  def defer_for_coexistence_throughput?(message)
    return false unless whatsapp_channel.provider_config.to_h['embedded_signup_flow'] == 'coexistence'

    counter_key = "whatsapp:coexistence:throughput:#{whatsapp_channel.id}:#{Time.current.to_i}"
    count = Redis::Alfred.incr(counter_key)
    Redis::Alfred.expire(counter_key, 120) if count == 1
    return false if count <= COEXISTENCE_THROUGHPUT_LIMIT

    wait = ((count - 1) / COEXISTENCE_THROUGHPUT_LIMIT).seconds
    retry_at = wait.from_now
    content_attributes = coexistence_retry_content_attributes(message, retry_at)
    message.update!(status: :sent, external_error: nil, content_attributes: content_attributes)
    SendReplyJob.set(wait: wait).perform_later(message.id)
    true
  end

  def coexistence_retry_content_attributes(message, retry_at)
    message.content_attributes.to_h.deep_stringify_keys.except('external_error').merge(
      COEXISTENCE_THROTTLE_KEY => true,
      TRANSIENT_SEND_RETRY_NEXT_AT_KEY => retry_at.iso8601
    )
  end
end

Whatsapp::Providers::WhatsappCloudService.include_mod_with('Whatsapp::Providers::WhatsappCloudService')
