class Whatsapp::TemplateProcessorService
  UNSUPPORTED_COMPONENT_TYPES = %w[
    LIST
    PRODUCT
    CATALOG
    CAROUSEL
    LIMITED_TIME_OFFER
    CALL_PERMISSION_REQUEST
  ].freeze
  UNSUPPORTED_CATEGORIES = %w[AUTHENTICATION].freeze
  UNSUPPORTED_HEADER_FORMATS = %w[LOCATION].freeze

  pattr_initialize [:channel!, :template_params, :message]

  def call
    return [nil, nil, nil, nil] if template_params.blank?

    process_template_with_params
  end

  private

  def process_template_with_params
    [
      template_params['name'],
      template_params['namespace'],
      template_params['language'],
      processed_templates_params
    ]
  end

  def find_template
    return unless channel.message_templates.is_a?(Array)

    channel.message_templates.find do |template|
      template['name'] == template_params['name'] &&
        template['language']&.downcase == template_params['language']&.downcase &&
        template['status']&.downcase == 'approved' &&
        namespace_matches?(template) &&
        supported_template?(template)
    end
  end

  def processed_templates_params
    template = find_template
    return if template.blank?

    # Convert legacy format to enhanced format before processing
    converter = Whatsapp::TemplateParameterConverterService.new(template_params, template)
    normalized_params = converter.normalize_to_enhanced

    process_enhanced_template_params(template, normalized_params['processed_params'])
  end

  def process_enhanced_template_params(template, processed_params = nil)
    processed_params ||= template_params['processed_params']
    processed_params = render_template_param_values(processed_params || {})
    components = []

    components.concat(process_header_components(processed_params))
    components.concat(process_body_components(processed_params, template))
    components.concat(process_footer_components(processed_params))
    components.concat(process_button_components(processed_params))

    @template_params = components
  end

  def process_header_components(processed_params)
    return [] if processed_params['header'].blank?

    header_params = build_header_params(processed_params['header'])
    header_params.present? ? [{ type: 'header', parameters: header_params }] : []
  end

  def build_header_params(header_data)
    header_params = []
    header_data.each do |key, value|
      next if value.blank?

      if media_url_with_type?(key, header_data)
        media_name = header_data['media_name']
        media_param = parameter_builder.build_media_parameter(value, header_data['media_type'], media_name)
        header_params << media_param if media_param
      elsif key != 'media_type' && key != 'media_name'
        header_params << parameter_builder.build_parameter(value)
      end
    end
    header_params
  end

  def media_url_with_type?(key, header_data)
    key == 'media_url' && header_data['media_type'].present?
  end

  def process_body_components(processed_params, template)
    return [] if processed_params['body'].blank?

    body_params = processed_params['body'].filter_map do |key, value|
      next if value.blank?

      parameter_format = template['parameter_format']
      if parameter_format == 'NAMED'
        parameter_builder.build_named_parameter(key, value)
      else
        parameter_builder.build_parameter(value)
      end
    end

    body_params.present? ? [{ type: 'body', parameters: body_params }] : []
  end

  def process_footer_components(processed_params)
    return [] if processed_params['footer'].blank?

    footer_params = processed_params['footer'].filter_map do |_, value|
      next if value.blank?

      parameter_builder.build_parameter(value)
    end

    footer_params.present? ? [{ type: 'footer', parameters: footer_params }] : []
  end

  def process_button_components(processed_params)
    return [] if processed_params['buttons'].blank?

    button_params = processed_params['buttons'].filter_map.with_index do |button, index|
      next if button.blank?

      if button['type'] == 'url' || button['parameter'].present?
        {
          type: 'button',
          sub_type: button['type'] || 'url',
          index: index,
          parameters: [parameter_builder.build_button_parameter(button)]
        }
      end
    end

    button_params.compact
  end

  def parameter_builder
    @parameter_builder ||= Whatsapp::PopulateTemplateParametersService.new
  end

  def render_template_param_values(value)
    case value
    when Hash
      value.transform_values { |item| render_template_param_values(item) }
    when Array
      value.map { |item| render_template_param_values(item) }
    when String
      render_template_param_string(value)
    else
      value
    end
  end

  def render_template_param_string(value)
    return value if message.blank?

    Outbound::RenderedTextService.new(
      content: value,
      conversation: message.conversation,
      contact: message.conversation&.contact,
      inbox: message.inbox || message.conversation&.inbox,
      account: message.account || message.conversation&.account,
      sender: message.sender
    ).render
  end

  def namespace_matches?(template)
    requested_namespace = template_params['namespace']
    template_namespace = template['namespace']

    requested_namespace.blank? || template_namespace.blank? || template_namespace == requested_namespace
  end

  def supported_template?(template)
    return false if UNSUPPORTED_CATEGORIES.include?(template['category'].to_s.upcase)

    components = template['components']
    return false unless components.is_a?(Array)

    components.none? do |component|
      unsupported_component_type?(component) || unsupported_header_format?(component)
    end
  end

  def unsupported_component_type?(component)
    UNSUPPORTED_COMPONENT_TYPES.include?(component['type'].to_s.upcase)
  end

  def unsupported_header_format?(component)
    component['type'].to_s.upcase == 'HEADER' && UNSUPPORTED_HEADER_FORMATS.include?(component['format'].to_s.upcase)
  end
end
