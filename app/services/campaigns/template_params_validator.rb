class Campaigns::TemplateParamsValidator
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
    Array(template[:required_params]).filter_map do |param|
      component = param[:component].to_s
      name = param[:name].to_s
      "#{component}.#{name}" if missing_param?(component, name)
    end
  end

  def missing_param?(component, name)
    processed = normalized_hash(template_params['processed_params'] || template_params[:processed_params])
    component_values = processed[component] || processed[component.to_sym]

    case component_values
    when Hash
      component_values[name].blank? && component_values[name.to_sym].blank?
    when Array
      component_values.none? { |item| value_present_in_button?(item, name) }
    else
      true
    end
  end

  def value_present_in_button?(item, name)
    values = normalized_hash(item)
    values[name].present? || values[name.to_sym].present? || values['parameter'].present? || values[:parameter].present?
  end

  def normalized_hash(value)
    value.respond_to?(:to_h) ? value.to_h.with_indifferent_access : {}.with_indifferent_access
  end
end
