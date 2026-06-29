class Whatsapp::TemplateManagementService
  DUPLICATE_TEMPLATE_ERROR_PATTERN = /already exists|duplicate|same name/i

  pattr_initialize [:whatsapp_channel!]

  def create_template(template_config)
    request_body = template_request_builder(template_config).call
    response = whatsapp_channel.provider_service.create_template(request_body)

    return handle_template_create_failure(response, request_body) unless response.success?

    create_success_result(response.parsed_response, request_body)
  rescue ArgumentError => e
    failure_result(e.message)
  rescue StandardError => e
    return handle_timeout_recovery(request_body, e) if request_body && recoverable_timeout_error?(e)

    Rails.logger.error "[WHATSAPP TEMPLATE MANAGEMENT] create failed for channel=#{whatsapp_channel.id}: #{e.class}: #{e.message}"
    internal_failure_result(e)
  end

  def delete_template(template_name)
    response = whatsapp_channel.provider_service.delete_template(template_name)

    return provider_failure_result(response, default_message: 'Template deletion failed') unless response.success?

    remove_local_template(template_name)
    enqueue_sync

    { success: true }
  rescue StandardError => e
    Rails.logger.error "[WHATSAPP TEMPLATE MANAGEMENT] delete failed for channel=#{whatsapp_channel.id}: #{e.class}: #{e.message}"
    internal_failure_result(e)
  end

  private

  def template_request_builder(template_config)
    Whatsapp::TemplateRequestBuilderService.new(
      template_config: template_config,
      asset_upload_service: Whatsapp::TemplateAssetUploadService.new(whatsapp_channel: whatsapp_channel)
    )
  end

  def create_success_result(response_body, request_body)
    template = build_local_template(response_body, request_body)
    upsert_local_template(template)
    enqueue_sync

    { success: true, template: template }
  end

  def handle_template_create_failure(response, request_body)
    recovery_result = recover_remote_template(request_body, response: response)
    return recovery_result if recovery_result[:success]

    provider_failure_result(response, default_message: 'Template creation failed')
  end

  def handle_timeout_recovery(request_body, error)
    recovery_result = recover_remote_template(request_body, exception: error)
    return recovery_result if recovery_result[:success]

    enqueue_sync
    failure_result(
      'Template creation is taking longer than expected. Template sync has been queued. Please sync templates again in a minute.',
      details: { retryable: true, sync_queued: true, error_class: error.class.name }
    )
  end

  def recover_remote_template(request_body, response: nil, exception: nil)
    return failure_result(nil) unless recoverable_template_result?(response, exception)

    remote_template = find_remote_template(request_body[:name], request_body[:language])
    return failure_result(nil) if remote_template.blank?

    template = normalize_remote_template(remote_template, request_body)
    upsert_local_template(template)
    enqueue_sync

    { success: true, recovered: true, template: template }
  rescue StandardError => e
    Rails.logger.warn(
      "[WHATSAPP TEMPLATE MANAGEMENT] recovery failed for channel=#{whatsapp_channel.id}: #{e.class}: #{e.message}"
    )
    failure_result(nil)
  end

  def recoverable_template_result?(response, exception)
    return true if exception && recoverable_timeout_error?(exception)
    return false if response.blank?

    error_payload = parse_provider_error(response.body)
    error_message = [error_payload[:user_message], error_payload[:details]].compact.join(' ')
    error_message.match?(DUPLICATE_TEMPLATE_ERROR_PATTERN)
  end

  def recoverable_timeout_error?(error)
    error.is_a?(Net::OpenTimeout) ||
      error.is_a?(Net::ReadTimeout) ||
      error.is_a?(Timeout::Error) ||
      rack_timeout_error?(error)
  end

  def rack_timeout_error?(error) = defined?(::Rack::Timeout::RequestTimeoutException) && error.instance_of?(::Rack::Timeout::RequestTimeoutException)

  def find_remote_template(template_name, language)
    Array(whatsapp_channel.provider_service.fetch_templates).find do |template|
      template['name'].to_s.casecmp?(template_name.to_s) &&
        template['language'].to_s.casecmp?(language.to_s)
    end
  end

  def normalize_remote_template(remote_template, request_body)
    remote_template = remote_template.deep_stringify_keys
    components = remote_template['components'].presence || request_body[:components]
    defaults = {
      'name' => request_body[:name],
      'status' => 'PENDING',
      'category' => request_body[:category],
      'language' => request_body[:language],
      'parameter_format' => 'POSITIONAL'
    }
    remote_attributes = remote_template.slice('id', 'name', 'status', 'category', 'language', 'parameter_format').compact

    defaults.merge(remote_attributes).merge('components' => Array(components).map(&:deep_stringify_keys))
  end

  def build_local_template(response_body, request_body)
    {
      'id' => response_body['id'],
      'name' => request_body[:name],
      'status' => response_body['status'] || 'PENDING',
      'category' => request_body[:category],
      'language' => request_body[:language],
      'parameter_format' => 'POSITIONAL',
      'components' => request_body[:components].map(&:deep_stringify_keys)
    }.compact
  end

  def upsert_local_template(template)
    templates = Array(whatsapp_channel.message_templates).dup
    template_index = templates.find_index do |existing_template|
      existing_template['name'] == template['name'] &&
        existing_template['language'].to_s.casecmp?(template['language'].to_s)
    end

    if template_index
      templates[template_index] = template
    else
      templates.unshift(template)
    end

    update_local_cache!(templates)
  end

  def remove_local_template(template_name)
    templates = Array(whatsapp_channel.message_templates).reject do |template|
      template['name'] == template_name
    end

    update_local_cache!(templates)
  end

  def update_local_cache!(templates)
    whatsapp_channel.update_message_templates_cache!(templates)
  end

  def enqueue_sync = Channels::Whatsapp::TemplatesSyncJob.perform_later(whatsapp_channel)

  def provider_failure_result(response, default_message:)
    error_payload = parse_provider_error(response.body)
    failure_result(
      error_payload[:user_message] || default_message,
      details: error_payload[:details],
      response_body: response.body
    )
  end

  def parse_provider_error(response_body)
    return { user_message: nil, details: nil } if response_body.blank?

    response_json = JSON.parse(response_body)
    provider_error = response_json['error'] || {}

    {
      user_message: provider_error['error_user_msg'] || provider_error['message'],
      details: {
        code: provider_error['code'],
        subcode: provider_error['error_subcode'],
        type: provider_error['type'],
        title: provider_error['error_user_title']
      }.compact
    }
  rescue JSON::ParserError
    { user_message: nil, details: response_body }
  end

  def failure_result(error, details: nil, response_body: nil)
    { success: false, error: error, details: details, response_body: response_body }
  end

  def internal_failure_result(error) = failure_result(error.message, details: nil, response_body: nil)
end
