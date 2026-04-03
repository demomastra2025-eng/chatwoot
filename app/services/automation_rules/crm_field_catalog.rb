class AutomationRules::CrmFieldCatalog
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
    'deal' => {
      'pipeline_id' => { field_type: 'select', operators: %w[equal_to not_equal_to is_present is_not_present] },
      'stage_id' => { field_type: 'select', operators: %w[equal_to not_equal_to is_present is_not_present] },
      'owner_id' => { field_type: 'select', operators: %w[equal_to not_equal_to is_present is_not_present] },
      'team_id' => { field_type: 'select', operators: %w[equal_to not_equal_to is_present is_not_present] },
      'title' => {
        field_type: 'text',
        operators: %w[equal_to not_equal_to contains does_not_contain starts_with is_present is_not_present]
      },
      'description' => {
        field_type: 'textarea',
        operators: %w[equal_to not_equal_to contains does_not_contain starts_with is_present is_not_present]
      },
      'currency' => {
        field_type: 'text',
        operators: %w[equal_to not_equal_to contains does_not_contain starts_with is_present is_not_present]
      },
      'external_ref' => {
        field_type: 'text',
        operators: %w[equal_to not_equal_to contains does_not_contain starts_with is_present is_not_present]
      },
      'amount_minor' => {
        field_type: 'number',
        operators: %w[equal_to not_equal_to is_greater_than is_less_than is_present is_not_present]
      },
      'win_probability' => {
        field_type: 'percent',
        operators: %w[equal_to not_equal_to is_greater_than is_less_than is_present is_not_present]
      },
      'expected_close_on' => {
        field_type: 'date',
        operators: %w[equal_to not_equal_to is_greater_than is_less_than is_present is_not_present]
      },
      'closed_at' => {
        field_type: 'datetime',
        operators: %w[equal_to not_equal_to is_greater_than is_less_than is_present is_not_present]
      },
      'archived_at' => {
        field_type: 'datetime',
        operators: %w[equal_to not_equal_to is_greater_than is_less_than is_present is_not_present]
      }
    },
    'task' => {
      'status_id' => { field_type: 'select', operators: %w[equal_to not_equal_to is_present is_not_present] },
      'assignee_id' => { field_type: 'select', operators: %w[equal_to not_equal_to is_present is_not_present] },
      'team_id' => { field_type: 'select', operators: %w[equal_to not_equal_to is_present is_not_present] },
      'priority' => { field_type: 'select', operators: %w[equal_to not_equal_to is_present is_not_present] },
      'title' => {
        field_type: 'text',
        operators: %w[equal_to not_equal_to contains does_not_contain starts_with is_present is_not_present]
      },
      'description' => {
        field_type: 'textarea',
        operators: %w[equal_to not_equal_to contains does_not_contain starts_with is_present is_not_present]
      },
      'external_ref' => {
        field_type: 'text',
        operators: %w[equal_to not_equal_to contains does_not_contain starts_with is_present is_not_present]
      },
      'start_at' => {
        field_type: 'datetime',
        operators: %w[equal_to not_equal_to is_greater_than is_less_than is_present is_not_present]
      },
      'due_at' => {
        field_type: 'datetime',
        operators: %w[equal_to not_equal_to is_greater_than is_less_than is_present is_not_present]
      },
      'completed_at' => {
        field_type: 'datetime',
        operators: %w[equal_to not_equal_to is_greater_than is_less_than is_present is_not_present]
      },
      'archived_at' => {
        field_type: 'datetime',
        operators: %w[equal_to not_equal_to is_greater_than is_less_than is_present is_not_present]
      }
    }
  }.freeze

  def initialize(account:, entity_kind:)
    @account = account
    @entity_kind = entity_kind.to_s
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

  def standard_field_keys
    standard_definitions.keys
  end

  def supported_attribute?(key)
    standard_field?(key) || custom_field?(key)
  end

  def supported_attributes
    standard_field_keys + custom_field_keys
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

  attr_reader :account, :entity_kind

  def custom_definitions
    @custom_definitions ||= account.crm_field_definitions
                                   .active
                                   .for_entity_kind(entity_kind)
                                   .ordered
                                   .select { |definition| definition.field_type.in?(CUSTOM_FIELD_TYPES) }
  end

  def standard_definition_for(key)
    standard_definitions[key.to_s]
  end

  def standard_definitions
    STANDARD_CONDITIONS.fetch(entity_kind, {})
  end
end
