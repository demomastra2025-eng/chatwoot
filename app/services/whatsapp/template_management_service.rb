class Whatsapp::TemplateManagementService
  pattr_initialize [:whatsapp_channel!]

  def create_template(template_config)
    request_body = template_request_builder(template_config).call
    response = whatsapp_channel.provider_service.create_template(request_body)

    return provider_failure_result(response, default_message: 'Template creation failed') unless response.success?

    template = build_local_template(response.parsed_response, request_body)
    upsert_local_template(template)
    enqueue_sync

    {
      success: true,
      template: template
    }
  rescue ArgumentError => e
    failure_result(e.message)
  rescue StandardError => e
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
    # rubocop:disable Rails/SkipsModelValidations
    whatsapp_channel.update_columns(
      message_templates: templates,
      message_templates_last_updated: Time.current.utc
    )
    # rubocop:enable Rails/SkipsModelValidations
  end

  def enqueue_sync
    Channels::Whatsapp::TemplatesSyncJob.perform_later(whatsapp_channel)
  end

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
    {
      success: false,
      error: error,
      details: details,
      response_body: response_body
    }
  end

  def internal_failure_result(error)
    failure_result(error.message, details: nil, response_body: nil)
  end
end
