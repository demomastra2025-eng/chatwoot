class Outbound::ChannelTemplateCatalog
  DEFAULT_LIMIT = 50
  SUPPORTED_WHATSAPP_STATUSES = %w[approved].freeze
  UNSUPPORTED_WHATSAPP_COMPONENT_TYPES = %w[
    LIST
    PRODUCT
    CATALOG
    CAROUSEL
    LIMITED_TIME_OFFER
    CALL_PERMISSION_REQUEST
  ].freeze
  UNSUPPORTED_WHATSAPP_CATEGORIES = %w[AUTHENTICATION].freeze
  UNSUPPORTED_WHATSAPP_HEADER_FORMATS = %w[LOCATION].freeze

  def self.for(inbox:, **filters)
    new(inbox: inbox).as_json(**filters)
  end

  def initialize(inbox:)
    @inbox = inbox
  end

  def as_json(name: nil, language: nil, status: 'approved', limit: DEFAULT_LIMIT)
    selected_templates = filtered_templates(name: name, language: language, status: status).first(normalized_limit(limit))

    base_payload.merge(
      templates: selected_templates,
      total_count: selected_templates.size,
      filters: { name: name.presence, language: language.presence, status: status.presence }.compact
    )
  end

  def find_template(template_params)
    params = normalized_params(template_params)
    return if params.blank?

    filtered_templates(
      name: params['name'],
      language: params['language'],
      status: 'approved'
    ).find { |template| template_matches_params?(template, params) && template[:supported] }
  end

  def supports_channel_templates?
    whatsapp_business_api? || twilio_whatsapp?
  end

  private

  attr_reader :inbox

  def base_payload
    {
      inbox_id: inbox&.id,
      inbox_name: inbox&.name,
      channel_type: inbox&.channel_type,
      provider: provider_name,
      supports_channel_templates: supports_channel_templates?,
      requires_template_for_outside_window: supports_channel_templates?,
      templates_last_updated_at: templates_last_updated_at&.iso8601,
      notes: notes
    }
  end

  def filtered_templates(name:, language:, status:)
    templates = normalized_templates
    templates = templates.select { |template| template[:name].to_s == name.to_s } if name.present?
    templates = templates.select { |template| template[:language].to_s.casecmp(language.to_s).zero? } if language.present?
    templates = templates.select { |template| template[:status].to_s.casecmp(status.to_s).zero? } if status.present?
    templates
  end

  def normalized_templates
    return normalized_whatsapp_templates if whatsapp_business_api?
    return normalized_twilio_templates if twilio_whatsapp?

    []
  end

  def normalized_whatsapp_templates
    Array(channel.message_templates).filter_map do |template|
      next unless template.is_a?(Hash)

      normalize_whatsapp_template(template.with_indifferent_access)
    end
  end

  def normalized_twilio_templates
    templates = channel.content_templates&.dig('templates') || channel.content_templates&.dig(:templates)
    Array(templates).filter_map do |template|
      next unless template.is_a?(Hash)

      normalize_twilio_template(template.with_indifferent_access)
    end
  end

  def normalize_whatsapp_template(template)
    components = Array(template['components'])
    body_component = component_by_type(components, 'BODY')
    header_component = component_by_type(components, 'HEADER')
    footer_component = component_by_type(components, 'FOOTER')

    {
      transport: 'whatsapp_cloud',
      id: template['id'],
      name: template['name'],
      language: template['language'],
      status: template['status'].to_s.downcase,
      category: template['category'],
      namespace: template['namespace'],
      parameter_format: template['parameter_format'].presence || 'POSITIONAL',
      body: body_component&.dig('text'),
      header: header_payload(header_component),
      footer: footer_component&.dig('text'),
      buttons: button_payloads(components),
      required_params: required_whatsapp_params(template, components),
      components: components,
      rejected_reason: template['rejected_reason'],
      supported: supported_whatsapp_template?(template)
    }.compact
  end

  def normalize_twilio_template(template)
    {
      transport: 'twilio_whatsapp',
      content_sid: template['content_sid'],
      name: template['friendly_name'],
      language: template['language'],
      status: template['status'].to_s.downcase,
      category: template['category'],
      template_type: template['template_type'],
      media_type: template['media_type'],
      body: template['body'],
      variables: template['variables'] || {},
      required_params: twilio_required_params(template),
      supported: template['status'].to_s.downcase == 'approved'
    }.compact
  end

  def template_matches_params?(template, params)
    if template[:transport].to_s == 'twilio_whatsapp'
      return false if params['content_sid'].present? && template[:content_sid].to_s != params['content_sid'].to_s
      return false if params['name'].present? && template[:name].to_s != params['name'].to_s
      return false if params['content_sid'].blank? && params['name'].blank?
    else
      return false unless template[:name].to_s == params['name'].to_s
      return false if params['namespace'].present? && template[:namespace].present? && template[:namespace].to_s != params['namespace'].to_s
    end

    return false if params['language'].present? && !template[:language].to_s.casecmp(params['language'].to_s).zero?

    true
  end

  def required_whatsapp_params(template, components)
    components.flat_map do |component|
      component_type = component['type'].to_s.downcase
      text_params = params_from_text(component['text']).map do |param_name|
        {
          component: component_type,
          name: param_name,
          example: whatsapp_param_example(template, component_type, param_name)
        }.compact
      end
      text_params + media_header_params(component) + button_params(component)
    end
  end

  def button_params(component)
    return [] unless component['type'].to_s.casecmp('BUTTONS').zero?

    params = []
    Array(component['buttons']).each_with_index do |button, index|
      next unless button_param_required?(button)

      params << {
        component: 'buttons',
        name: index.to_s,
        type: button['type'].to_s.downcase
      }.compact
    end
    params
  end

  def button_param_required?(button)
    button_type = button['type'].to_s.upcase
    button_type == 'COPY_CODE' || (button_type == 'URL' && button['url'].to_s.include?('{{'))
  end

  def media_header_params(component)
    return [] unless component['type'].to_s.casecmp('HEADER').zero?
    return [] unless %w[IMAGE VIDEO DOCUMENT].include?(component['format'].to_s.upcase)

    [
      { component: 'header', name: 'media_url', type: component['format'].to_s.downcase },
      { component: 'header', name: 'media_type', type: 'string', example: component['format'].to_s.downcase }
    ]
  end

  def whatsapp_param_example(template, component_type, param_name)
    component = component_by_type(Array(template['components']), component_type.upcase)
    examples = component&.dig('example') || {}
    named_examples = examples['body_text_named_params'] || examples[:body_text_named_params]
    named_match = Array(named_examples).find { |item| item['param_name'].to_s == param_name.to_s || item[:param_name].to_s == param_name.to_s }
    return named_match['example'] || named_match[:example] if named_match.present?

    positional_examples = examples['body_text'] || examples[:body_text]
    Array(positional_examples).flatten[param_name.to_i - 1] if param_name.to_s.match?(/\A\d+\z/)
  end

  def twilio_required_params(template)
    variables = template['variables'] || {}
    variables.keys.map do |key|
      { component: 'body', name: key.to_s, example: variables[key].to_s.presence }.compact
    end
  end

  def params_from_text(text)
    text.to_s.scan(/{{\s*([^}\s]+)\s*}}/).flatten.uniq
  end

  def component_by_type(components, type)
    components.find { |component| component['type'].to_s.casecmp(type.to_s).zero? }
  end

  def header_payload(component)
    return if component.blank?

    {
      type: component['type'],
      format: component['format'],
      text: component['text']
    }.compact
  end

  def button_payloads(components)
    Array(components).select { |component| component['type'].to_s.casecmp('BUTTONS').zero? }.flat_map { |component| Array(component['buttons']) }
  end

  def supported_whatsapp_template?(template)
    return false unless SUPPORTED_WHATSAPP_STATUSES.include?(template['status'].to_s.downcase)
    return false if UNSUPPORTED_WHATSAPP_CATEGORIES.include?(template['category'].to_s.upcase)

    components = Array(template['components'])
    components.none? do |component|
      UNSUPPORTED_WHATSAPP_COMPONENT_TYPES.include?(component['type'].to_s.upcase) ||
        (component['type'].to_s.upcase == 'HEADER' && UNSUPPORTED_WHATSAPP_HEADER_FORMATS.include?(component['format'].to_s.upcase))
    end
  end

  def notes
    return ['Approved WhatsApp templates are required when the 24-hour reply window is closed.'] if whatsapp_business_api?
    return ['Approved Twilio WhatsApp content templates are required when the 24-hour reply window is closed.'] if twilio_whatsapp?

    ['This channel does not require channel templates for normal outbound messages.']
  end

  def provider_name
    return channel.provider if whatsapp_business_api?
    return 'twilio_whatsapp' if twilio_whatsapp?

    channel&.class&.name
  end

  def templates_last_updated_at
    return channel.message_templates_last_updated if whatsapp_business_api?
    return channel.content_templates_last_updated if twilio_whatsapp?
  end

  def normalized_params(template_params)
    template_params.respond_to?(:to_h) ? template_params.to_h.with_indifferent_access : {}
  end

  def normalized_limit(value)
    numeric = value.to_i
    numeric = DEFAULT_LIMIT if numeric <= 0
    [numeric, DEFAULT_LIMIT].min
  end

  def whatsapp_business_api?
    channel.is_a?(Channel::Whatsapp)
  end

  def twilio_whatsapp?
    channel.is_a?(Channel::TwilioSms) && channel.medium == 'whatsapp'
  end

  def channel
    inbox&.channel
  end
end
