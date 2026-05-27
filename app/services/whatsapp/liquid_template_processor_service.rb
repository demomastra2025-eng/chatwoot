class Whatsapp::LiquidTemplateProcessorService
  LIQUID_EXPRESSION = /\{\{\s*(.+?)\s*\}\}/
  BLANK_RENDER = Object.new.freeze

  pattr_initialize [:campaign!, :contact!]

  def process_template_params(template_params)
    return template_params if template_params.blank?

    template_params_copy = template_params.deep_dup
    processed_params = template_params_copy['processed_params']
    return template_params_copy if processed_params.blank?

    rendered_params = render_liquid(processed_params)
    return nil if rendered_params.equal?(BLANK_RENDER)

    template_params_copy.merge('processed_params' => rendered_params)
  end

  private

  def render_liquid(value)
    case value
    when Hash then render_liquid_hash(value)
    when Array then render_liquid_array(value)
    when String then render_liquid_string(value)
    else value
    end
  end

  def render_liquid_hash(hash)
    hash.each_with_object({}) do |(key, value), rendered_hash|
      rendered_value = render_liquid(value)
      return BLANK_RENDER if rendered_value.equal?(BLANK_RENDER)

      rendered_hash[key] = rendered_value
    end
  end

  def render_liquid_array(array)
    array.map do |value|
      rendered_value = render_liquid(value)
      return BLANK_RENDER if rendered_value.equal?(BLANK_RENDER)

      rendered_value
    end
  end

  def render_liquid_string(string)
    return string unless string.match?(LIQUID_EXPRESSION)

    blank_expression = false
    rendered = string.gsub(LIQUID_EXPRESSION) do
      expression = Regexp.last_match(1)
      expression_value = Liquid::Template.parse("{{ #{expression} }}").render!(drops)
      blank_expression = true if expression_value.blank?
      expression_value
    end

    return BLANK_RENDER if blank_expression

    rendered
  end

  def drops
    {
      'contact' => ContactDrop.new(contact),
      'agent' => UserDrop.new(campaign.sender),
      'inbox' => InboxDrop.new(campaign.inbox),
      'account' => AccountDrop.new(campaign.account)
    }
  end
end
