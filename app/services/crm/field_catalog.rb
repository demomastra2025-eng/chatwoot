class Crm::FieldCatalog
  attr_reader :account, :context, :entity_kind

  def initialize(account:, entity_kind:, context: nil)
    @account = account
    @entity_kind = entity_kind.to_s
    @context = context
  end

  def definitions
    @definitions ||= account.crm_field_definitions
                            .active
                            .for_entity_kind(entity_kind)
                            .ordered
                            .select { |definition| applicable_to_context?(definition) }
  end

  def definition_by_key(key)
    definitions.find { |definition| definition.key == key.to_s }
  end

  def resolve_custom_attributes(current_attributes:, incoming_attributes:, apply_defaults:)
    resolved = current_attributes
               .to_h
               .deep_stringify_keys
               .slice(*definitions.map(&:key))
    incoming = incoming_attributes.nil? ? {} : incoming_attributes.to_h.deep_stringify_keys

    incoming.each do |key, value|
      definition = definition_by_key(key)
      raise_validation_error("custom_attributes.#{key}", 'is not a known active field') if definition.blank?

      normalized_value = normalize_value(definition, value)
      normalized_value.nil? ? resolved.delete(key) : resolved[key] = normalized_value
    end

    apply_default_values!(resolved) if apply_defaults
    validate_required_fields!(resolved)

    resolved
  end

  private

  def applicable_to_context?(definition)
    contexts = Array(rule_value(definition, 'contexts')).presence
    return true if contexts.blank?

    context.present? && contexts.map(&:to_s).include?(context)
  end

  def apply_default_values!(resolved)
    definitions.each do |definition|
      next if resolved.key?(definition.key)
      next if definition.default_value.nil?

      resolved[definition.key] = deep_dup_value(definition.default_value)
    end
  end

  def deep_dup_value(value)
    value.is_a?(Array) || value.is_a?(Hash) ? value.deep_dup : value
  end

  def normalize_boolean(value)
    ActiveModel::Type::Boolean.new.cast(value)
  end

  def normalize_datetime(value)
    return nil if blank_like?(value)

    parsed = value.is_a?(Time) || value.is_a?(ActiveSupport::TimeWithZone) ? value : Time.zone.parse(value.to_s)
    raise_validation_error('custom_attributes', 'contains an invalid datetime value') if parsed.blank?

    parsed.iso8601
  end

  def normalize_date(value)
    return nil if blank_like?(value)

    parsed = value.is_a?(Date) ? value : Date.iso8601(value.to_s)
    parsed.iso8601
  rescue Date::Error
    raise_validation_error('custom_attributes', 'contains an invalid date value')
  end

  def normalize_multiselect(definition, value)
    items = Array(value).map { |item| normalize_text(item) }.compact
    invalid_values = items - option_values(definition)
    raise_validation_error("custom_attributes.#{definition.key}", 'contains a value outside allowed options') if invalid_values.any?

    items
  end

  def normalize_number(value, integer_only: false)
    return nil if blank_like?(value)
    return value if value.is_a?(Numeric)

    integer_only || value.to_s.exclude?('.') ? Integer(value) : Float(value)
  rescue ArgumentError, TypeError
    raise_validation_error('custom_attributes', 'contains an invalid numeric value')
  end

  def normalize_select(definition, value)
    normalized_value = normalize_text(value)
    return nil if normalized_value.blank?

    unless option_values(definition).include?(normalized_value)
      raise_validation_error("custom_attributes.#{definition.key}",
                             'contains a value outside allowed options')
    end

    normalized_value
  end

  def normalize_text(value)
    value.to_s.strip.presence
  end

  def normalize_value(definition, value)
    normalized = case definition.field_type
                 when 'checkbox'
                   normalize_boolean(value)
                 when 'currency'
                   normalize_number(value, integer_only: true)
                 when 'date'
                   normalize_date(value)
                 when 'datetime'
                   normalize_datetime(value)
                 when 'multiselect'
                   normalize_multiselect(definition, value)
                 when 'number'
                   normalize_number(value)
                 when 'percent'
                   normalize_percent(definition, value)
                 when 'select'
                   normalize_select(definition, value)
                 else
                   normalize_text(value)
                 end

    validate_rules!(definition, normalized)
    normalized
  end

  def normalize_percent(definition, value)
    normalized = normalize_number(value, integer_only: true)
    return nil if normalized.nil?

    raise_validation_error("custom_attributes.#{definition.key}", 'must be between 0 and 100') unless normalized.between?(0, 100)

    normalized
  end

  def option_values(definition)
    Array(definition.options).map do |option|
      option.is_a?(Hash) ? option.with_indifferent_access[:value].to_s : option.to_s
    end
  end

  def raise_validation_error(attribute, message)
    raise ::Crm::Error.new(
      code: 'VALIDATION_ERROR',
      message: "#{attribute} #{message}",
      status: :unprocessable_content,
      details: { attribute => [message] }
    )
  end

  def rule_value(definition, key)
    rules = definition.rules.with_indifferent_access
    rules[key]
  end

  def validate_required_fields!(resolved)
    definitions.select(&:required?).each do |definition|
      next if value_present?(resolved[definition.key])

      raise_validation_error("custom_attributes.#{definition.key}", 'is required')
    end
  end

  def validate_rules!(definition, value)
    return if value.nil?

    min = rule_value(definition, 'min')
    max = rule_value(definition, 'max')
    regex = rule_value(definition, 'regex')

    if value.is_a?(Numeric)
      raise_validation_error("custom_attributes.#{definition.key}", "must be greater than or equal to #{min}") if min.present? && value < min.to_f
      raise_validation_error("custom_attributes.#{definition.key}", "must be less than or equal to #{max}") if max.present? && value > max.to_f
    end

    return if regex.blank? || !value.is_a?(String)

    raise_validation_error("custom_attributes.#{definition.key}", 'has invalid format') unless Regexp.new(regex).match?(value)
  rescue RegexpError
    raise_validation_error("custom_attributes.#{definition.key}", 'has an invalid regex rule')
  end

  def value_present?(value)
    return true if value == false

    value.present?
  end

  def blank_like?(value)
    value.respond_to?(:blank?) ? value.blank? : value.nil?
  end
end
