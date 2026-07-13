class Campaigns::TemplateParamsValidator
  COMPONENT_KEYS = %w[body header footer buttons].freeze

  def self.validate!(inbox:, template_params:)
    new(inbox: inbox, template_params: template_params).validate!
  end

  def initialize(inbox:, template_params:)
    @inbox = inbox
    @template_params = normalized_hash(template_params)
  end

  def validate!
    return true unless catalog.supports_channel_templates?
    return true if template_params.blank?

    template = catalog.find_template(template_params)
    raise ArgumentError, 'Approved channel template was not found for template_params' if template.blank?

    missing_params = missing_required_params(template)
    raise ArgumentError, "Template params missing required values: #{missing_params.join(', ')}" if missing_params.present?

    true
  end

  private

  attr_reader :inbox, :template_params

  def catalog
    @catalog ||= Outbound::ChannelTemplateCatalog.new(inbox: inbox)
  end

  def missing_required_params(template)
    processed_params = normalized_processed_params(template)

    Array(template[:required_params]).filter_map do |param|
      component = param[:component].to_s
      name = param[:name].to_s
      "#{component}.#{name}" if missing_param?(processed_params, component, name)
    end
  end

  def missing_param?(processed_params, component, name)
    component_values = processed_params[component] || processed_params[component.to_sym]

    case component_values
    when Hash
      component_values[name].blank? && component_values[name.to_sym].blank?
    when Array
      missing_array_param?(component_values, name)
    else
      true
    end
  end

  def missing_array_param?(component_values, name)
    return component_values[name.to_i].then { |item| !button_parameter_present?(item) } if name.to_s.match?(/\A\d+\z/)

    component_values.none? { |item| value_present_in_button?(item, name) }
  end

  def value_present_in_button?(item, name)
    values = normalized_hash(item)
    values[name].present? || values[name.to_sym].present? ||
      ((values['key'].to_s == name.to_s || values[:key].to_s == name.to_s) && button_parameter_present?(values))
  end

  def button_parameter_present?(item)
    values = normalized_hash(item)
    values['parameter'].present? || values[:parameter].present?
  end

  def normalized_processed_params(template)
    processed_params = template_params['processed_params'] || template_params[:processed_params]
    return normalized_hash(processed_params) unless template[:transport].to_s == 'whatsapp_cloud'
    return normalized_hash(processed_params) if component_params?(processed_params)

    normalized = Whatsapp::TemplateParameterConverterService.new(
      template_params.deep_dup,
      template[:raw] || template
    ).normalize_to_enhanced
    normalized_hash(normalized['processed_params'])
  end

  def component_params?(value)
    return false unless value.is_a?(Hash)

    params = value.with_indifferent_access
    component_key_present?(params) && hash_components_valid?(params) && buttons_component_valid?(params)
  end

  def component_key_present?(params)
    COMPONENT_KEYS.any? { |key| params.key?(key) }
  end

  def hash_components_valid?(params)
    %w[body header footer].all? { |key| params[key].nil? || params[key].is_a?(Hash) }
  end

  def buttons_component_valid?(params)
    params['buttons'].nil? || params['buttons'].is_a?(Array)
  end

  def normalized_hash(value)
    value.respond_to?(:to_h) ? value.to_h.with_indifferent_access : {}.with_indifferent_access
  end
end
