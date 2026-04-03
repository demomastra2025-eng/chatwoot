class AutomationRules::AppointmentFieldCatalog
  DISCRETE_FIELD_TYPES = %w[checkbox select multiselect].freeze
  TEXT_FIELD_TYPES = %w[text textarea url].freeze
  NUMERIC_FIELD_TYPES = %w[number currency percent].freeze
  TEMPORAL_FIELD_TYPES = %w[date datetime].freeze
  CUSTOM_FIELD_TYPES = (
    DISCRETE_FIELD_TYPES +
    TEXT_FIELD_TYPES +
    NUMERIC_FIELD_TYPES +
    TEMPORAL_FIELD_TYPES
  ).freeze

  STANDARD_CONDITIONS = {
    'status' => {
      field_type: 'select',
      operators: %w[equal_to not_equal_to]
    },
    'payment_status' => {
      field_type: 'select',
      operators: %w[equal_to not_equal_to]
    },
    'appointment_type' => {
      field_type: 'select',
      operators: %w[equal_to not_equal_to]
    },
    'source' => {
      field_type: 'text',
      operators: %w[equal_to not_equal_to contains does_not_contain starts_with is_present is_not_present]
    }
  }.freeze

  def initialize(account:)
    @account = account
  end

  def custom_definition_for(key)
    custom_definitions.find { |definition| definition.key == key.to_s }
  end

  def custom_field?(key)
    custom_definition_for(key).present?
  end

  def custom_field_keys
    custom_definitions.map(&:key)
  end

  def field_type_for(key)
    standard_definition_for(key)&.fetch(:field_type) || custom_definition_for(key)&.field_type
  end

  def operator_supported?(key, operator)
    operator.to_s.in?(supported_operators_for(key))
  end

  def standard_field?(key)
    standard_definition_for(key).present?
  end

  def supported_attribute?(key)
    standard_field?(key) || custom_field?(key)
  end

  def supported_attributes
    STANDARD_CONDITIONS.keys + custom_field_keys
  end

  def supported_operators_for(key)
    return standard_definition_for(key)&.fetch(:operators, []) || [] if standard_field?(key)

    field_type = field_type_for(key)
    return %w[equal_to not_equal_to is_present is_not_present] if field_type.in?(DISCRETE_FIELD_TYPES)
    return %w[equal_to not_equal_to contains does_not_contain starts_with is_present is_not_present] if field_type.in?(TEXT_FIELD_TYPES)
    return %w[equal_to not_equal_to is_greater_than is_less_than is_present is_not_present] if field_type.in?(NUMERIC_FIELD_TYPES)
    return %w[equal_to not_equal_to is_greater_than is_less_than is_present is_not_present] if field_type.in?(TEMPORAL_FIELD_TYPES)

    []
  end

  private

  attr_reader :account

  def custom_definitions
    @custom_definitions ||= account.crm_field_definitions
                                   .active
                                   .for_entity_kind('appointment')
                                   .ordered
                                   .select { |definition| definition.field_type.in?(CUSTOM_FIELD_TYPES) }
  end

  def standard_definition_for(key)
    STANDARD_CONDITIONS[key.to_s]
  end
end
