# rubocop:disable Metrics/ClassLength
class Whatsapp::TemplateRequestBuilderService
  SUPPORTED_CATEGORIES = %w[UTILITY MARKETING].freeze
  SUPPORTED_HEADER_TYPES = %w[none text image video document].freeze
  SUPPORTED_BUTTON_TYPES = %w[QUICK_REPLY URL COPY_CODE PHONE_NUMBER].freeze
  TEMPLATE_NAME_FORMAT = /\A[a-z0-9_]+\z/
  PHONE_NUMBER_FORMAT = /\A\+[1-9]\d{1,14}\z/
  VARIABLE_PATTERN = /{{\s*(\d+)\s*}}/
  NUMERIC_PLACEHOLDER_PATTERN = /\A\d+\z/
  LEADING_VARIABLE_PATTERN = /\A#{VARIABLE_PATTERN}/o
  TRAILING_VARIABLE_PATTERN = /#{VARIABLE_PATTERN}\z/o

  pattr_initialize [:template_config!, :asset_upload_service!]

  def call
    {
      name: template_name,
      language: language,
      category: category,
      components: build_components
    }
  end

  private

  def build_components
    components = [build_body_component]
    header_component = build_header_component
    components << header_component if header_component.present?

    footer_component = build_footer_component
    components << footer_component if footer_component.present?

    buttons_component = build_buttons_component
    components << buttons_component if buttons_component.present?

    components
  end

  def build_body_component
    text = required_string_value(:body_text, 'Body text is required')
    variables = extract_variables(text, context: 'Body text', allow_dangling: false)

    component = {
      type: 'BODY',
      text: text
    }
    example_values = example_values_for(:body_examples, variables, 'Body text')
    component[:example] = { body_text: [example_values] } if example_values.present?
    component
  end

  def build_header_component
    case header_type
    when 'none'
      nil
    when 'text'
      build_text_header_component
    else
      build_media_header_component
    end
  end

  def build_text_header_component
    text = required_string_value(:header_text, 'Header text is required')
    variables = extract_variables(text, context: 'Header text', allow_dangling: false)

    component = {
      type: 'HEADER',
      format: 'TEXT',
      text: text
    }
    example_values = example_values_for(:header_examples, variables, 'Header text')
    component[:example] = { header_text: example_values } if example_values.present?
    component
  end

  def build_media_header_component
    handle = asset_upload_service.upload(
      url: required_string_value(:sample_media_url, 'Sample media URL is required'),
      media_type: header_type
    )

    {
      type: 'HEADER',
      format: header_type.upcase,
      example: {
        header_handle: [handle]
      }
    }
  end

  def build_footer_component
    return if config[:footer_text].blank?

    {
      type: 'FOOTER',
      text: string_value(:footer_text)
    }
  end

  def build_buttons_component
    buttons = Array(config[:buttons]).filter_map do |button|
      next if button.blank?

      build_button(button.with_indifferent_access)
    end

    return if buttons.blank?
    raise ArgumentError, 'You can add up to 3 buttons' if buttons.size > 3

    {
      type: 'BUTTONS',
      buttons: buttons
    }
  end

  def build_button(button)
    button_type = button.fetch(:type, '').to_s.upcase
    raise ArgumentError, "Unsupported button type: #{button_type}" unless SUPPORTED_BUTTON_TYPES.include?(button_type)

    case button_type
    when 'QUICK_REPLY'
      build_quick_reply_button(button)
    when 'URL'
      build_url_button(button)
    when 'COPY_CODE'
      build_copy_code_button(button)
    when 'PHONE_NUMBER'
      build_phone_number_button(button)
    end
  end

  def build_quick_reply_button(button)
    {
      type: 'QUICK_REPLY',
      text: required_value(button[:text], 'Quick reply button text is required')
    }
  end

  def build_url_button(button)
    url = required_value(button[:url], 'URL button target is required')
    variables = extract_variables(url, context: 'URL button')
    raise ArgumentError, 'URL buttons can contain at most one variable' if variables.size > 1

    validate_template_url!(url, 'URL button target')

    button_payload = {
      type: 'URL',
      text: required_value(button[:text], 'URL button text is required'),
      url: url
    }

    if variables.any?
      validate_url_button_suffix!(url)
      button_payload[:example] = [normalize_url_button_example(url, button[:example])]
    end

    button_payload
  end

  def build_copy_code_button(button)
    coupon_code = required_value(button[:example], 'Copy code example is required')
    raise ArgumentError, 'Copy code example cannot exceed 15 characters' if coupon_code.length > 15

    button_payload = {
      type: 'COPY_CODE',
      example: coupon_code
    }

    text = button[:text].to_s.strip
    button_payload[:text] = text if text.present?
    button_payload
  end

  def build_phone_number_button(button)
    phone_number = required_value(button[:phone_number], 'Phone number button target is required')
    validate_phone_number!(phone_number)

    {
      type: 'PHONE_NUMBER',
      text: required_value(button[:text], 'Phone number button text is required'),
      phone_number: phone_number
    }
  end

  def example_values_for(key, variables, label)
    return [] if variables.blank?

    values_hash = config[key].presence&.with_indifferent_access || {}
    variables.map do |variable|
      required_value(values_hash[variable], "#{label} example for {{#{variable}}} is required")
    end
  end

  def extract_variables(text, context:, allow_dangling: true)
    placeholders = extracted_placeholders(text)
    return [] if placeholders.empty?

    validate_numeric_placeholders!(placeholders, context)
    unique_placeholders = validate_sequential_placeholders!(placeholders, context)
    validate_no_dangling_variable!(text, context) unless allow_dangling

    unique_placeholders.map(&:to_s)
  end

  def extracted_placeholders(text)
    text.to_s.scan(/{{\s*([^}]+)\s*}}/).flatten.map(&:strip)
  end

  def validate_numeric_placeholders!(placeholders, context)
    return if placeholders.all? { |placeholder| placeholder.match?(NUMERIC_PLACEHOLDER_PATTERN) }

    raise ArgumentError, "#{context} variables must use numeric placeholders like {{1}}"
  end

  def validate_sequential_placeholders!(placeholders, context)
    unique_placeholders = placeholders.map(&:to_i).uniq.sort
    expected_placeholders = (1..unique_placeholders.last).to_a
    return unique_placeholders if unique_placeholders == expected_placeholders

    raise ArgumentError, "#{context} variables must be sequential without gaps"
  end

  def validate_no_dangling_variable!(text, context)
    return unless starts_or_ends_with_variable?(text)

    raise ArgumentError, "#{context} cannot start or end with a variable"
  end

  def starts_or_ends_with_variable?(text)
    stripped_text = text.to_s.strip
    stripped_text.match?(LEADING_VARIABLE_PATTERN) || stripped_text.match?(TRAILING_VARIABLE_PATTERN)
  end

  def template_name
    name = required_string_value(:name, 'Template name is required')
    raise ArgumentError, 'Template name can only contain lowercase letters, numbers, and underscores' unless name.match?(TEMPLATE_NAME_FORMAT)

    name
  end

  def language
    required_string_value(:language, 'Template language is required')
  end

  def category
    normalized_category = required_string_value(:category, 'Template category is required').upcase
    raise ArgumentError, "Unsupported template category: #{normalized_category}" unless SUPPORTED_CATEGORIES.include?(normalized_category)

    normalized_category
  end

  def header_type
    value = config.fetch(:header_type, 'none').to_s.downcase
    raise ArgumentError, "Unsupported header type: #{value}" unless SUPPORTED_HEADER_TYPES.include?(value)

    value
  end

  def config
    @config ||= template_config.with_indifferent_access
  end

  def required_string_value(key, error_message)
    required_value(config[key], error_message)
  end

  def string_value(key)
    config[key].to_s.strip
  end

  def required_value(value, error_message)
    normalized_value = value.to_s.strip
    raise ArgumentError, error_message if normalized_value.blank?

    normalized_value
  end

  def validate_template_url!(value, label)
    normalized_value = value.to_s.gsub(VARIABLE_PATTERN, 'sample')
    validate_http_url!(normalized_value, label)
  end

  def validate_url_button_suffix!(value)
    return if value.match?(TRAILING_VARIABLE_PATTERN)

    raise ArgumentError, 'Dynamic URL button variable must be the final URL suffix'
  end

  def normalize_url_button_example(template_url, sample_value)
    normalized_value = required_value(sample_value, 'Sample suffix is required for dynamic URL buttons')
    return normalized_value unless http_url?(normalized_value)

    prefix = template_url.sub(VARIABLE_PATTERN, '')
    return normalized_value.delete_prefix(prefix) if normalized_value.start_with?(prefix)

    raise ArgumentError, 'Sample URL must match the configured URL button prefix'
  end

  def validate_http_url!(value, label)
    uri = URI.parse(value)
    return if uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)

    raise ArgumentError, "#{label} must start with http:// or https://"
  rescue URI::InvalidURIError
    raise ArgumentError, "#{label} must be a valid URL"
  end

  def http_url?(value)
    uri = URI.parse(value)
    uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)
  rescue URI::InvalidURIError
    false
  end

  def validate_phone_number!(value)
    return if value.match?(PHONE_NUMBER_FORMAT)

    raise ArgumentError, 'Phone number buttons must use E.164 format'
  end
end
# rubocop:enable Metrics/ClassLength
