class Crm::CustomFieldFilterSet
  DISCRETE_FILTERABLE_FIELD_TYPES = %w[checkbox select multiselect].freeze
  TEXT_FILTERABLE_FIELD_TYPES = %w[text textarea url].freeze
  NUMERIC_FILTERABLE_FIELD_TYPES = %w[number currency percent].freeze
  TEMPORAL_FILTERABLE_FIELD_TYPES = %w[date datetime].freeze
  FILTERABLE_FIELD_TYPES = (
    DISCRETE_FILTERABLE_FIELD_TYPES +
    TEXT_FILTERABLE_FIELD_TYPES +
    NUMERIC_FILTERABLE_FIELD_TYPES +
    TEMPORAL_FILTERABLE_FIELD_TYPES
  ).freeze
  VALUELESS_OPERATORS = %w[is_present is_not_present].freeze

  def initialize(account:, entity_kind:, raw_filters:)
    @account = account
    @entity_kind = entity_kind
    @raw_filters = normalize_raw_filters(raw_filters)
  end

  def apply(records)
    return records if normalized_filters.blank?

    return apply_to_relation(records) if records.is_a?(ActiveRecord::Relation)

    Array.wrap(records).select { |record| matches?(record) }
  end

  def matches?(record)
    normalized_filters.all? do |key, config|
      raw_value = record.custom_attributes&.[](key)
      field_type = config[:definition].field_type

      if DISCRETE_FILTERABLE_FIELD_TYPES.include?(field_type)
        matches_discrete_filter?(field_type, raw_value, config[:values])
      else
        matches_advanced_filter?(config, raw_value)
      end
    end
  end

  private

  attr_reader :account, :entity_kind, :raw_filters

  def active_definitions
    @active_definitions ||= account.crm_field_definitions
                                  .active
                                  .for_entity_kind(entity_kind)
                                  .ordered
                                  .select do |definition|
      FILTERABLE_FIELD_TYPES.include?(definition.field_type)
    end
  end

  def discrete_filter?(definition)
    DISCRETE_FILTERABLE_FIELD_TYPES.include?(definition.field_type)
  end

  def filter_value_for(definition)
    raw_value = raw_filters[definition.key] || raw_filters[definition.key.to_sym]
    raw_value = raw_value.to_unsafe_h if raw_value.is_a?(ActionController::Parameters)
    raw_value
  end

  def allowed_operators_for(definition)
    field_type = definition.field_type

    return %w[contains equals is_present is_not_present] if TEXT_FILTERABLE_FIELD_TYPES.include?(field_type)
    return %w[equals greater_than less_than is_present is_not_present] if NUMERIC_FILTERABLE_FIELD_TYPES.include?(field_type)
    return %w[on after before is_present is_not_present] if TEMPORAL_FILTERABLE_FIELD_TYPES.include?(field_type)

    []
  end

  def allowed_values_for(definition)
    case definition.field_type
    when 'checkbox'
      [true, false]
    else
      Array.wrap(definition.options).filter_map do |option|
        value =
          if option.is_a?(String)
            option
          elsif option.respond_to?(:with_indifferent_access)
            option.with_indifferent_access[:value]
          end

        value.presence&.to_s
      end
    end
  end

  def matches_discrete_filter?(field_type, raw_value, values)
    case field_type
    when 'checkbox'
      normalized_value = normalize_boolean(raw_value)
      !normalized_value.nil? && values.include?(normalized_value)
    when 'multiselect'
      candidate_values = Array.wrap(raw_value).filter_map { |value| value.presence&.to_s }
      candidate_values.present? && (candidate_values & values).present?
    else
      candidate_value = raw_value.presence&.to_s
      candidate_value.present? && values.include?(candidate_value)
    end
  end

  def matches_advanced_filter?(config, raw_value)
    operator = config[:operator]
    return value_present?(raw_value) if operator == 'is_present'
    return !value_present?(raw_value) if operator == 'is_not_present'

    field_type = config[:definition].field_type

    if TEXT_FILTERABLE_FIELD_TYPES.include?(field_type)
      candidate_value = raw_value.presence&.to_s
      return false if candidate_value.blank?

      return candidate_value.casecmp?(config[:value]) if operator == 'equals'

      return candidate_value.downcase.include?(config[:value].downcase) if operator == 'contains'
    end

    if NUMERIC_FILTERABLE_FIELD_TYPES.include?(field_type)
      candidate_value = normalize_number(raw_value)
      return false if candidate_value.nil?

      return candidate_value == config[:value] if operator == 'equals'
      return candidate_value > config[:value] if operator == 'greater_than'
      return candidate_value < config[:value] if operator == 'less_than'
    end

    if field_type == 'date'
      candidate_value = date_value(raw_value)
      return false if candidate_value.nil?

      return candidate_value == config[:value] if operator == 'on'
      return candidate_value > config[:value] if operator == 'after'
      return candidate_value < config[:value] if operator == 'before'
    end

    if field_type == 'datetime'
      candidate_value = datetime_value(raw_value)
      return false if candidate_value.nil?

      return candidate_value == config[:value] if operator == 'on'
      return candidate_value > config[:value] if operator == 'after'
      return candidate_value < config[:value] if operator == 'before'
    end

    false
  end

  def normalize_values_for(definition)
    raw_value = filter_value_for(definition)
    allowed_values = allowed_values_for(definition)

    Array.wrap(raw_value).filter_map do |value|
      normalized_value =
        if definition.field_type == 'checkbox'
          normalize_boolean(value)
        else
          value.presence&.to_s
        end

      normalized_value if allowed_values.include?(normalized_value)
    end.uniq
  end

  def normalize_advanced_filter_for(definition)
    raw_value = filter_value_for(definition)
    return unless raw_value.is_a?(Hash)

    operator = raw_value['operator'] || raw_value[:operator]
    operator = operator.to_s.presence
    return unless allowed_operators_for(definition).include?(operator)

    return { definition: definition, operator: operator } if VALUELESS_OPERATORS.include?(operator)

    value =
      case definition.field_type
      when *TEXT_FILTERABLE_FIELD_TYPES
        raw_value['value'].presence || raw_value[:value].presence
      when *NUMERIC_FILTERABLE_FIELD_TYPES
        normalize_number(raw_value['value'] || raw_value[:value])
      when 'date'
        normalize_date_filter(raw_value['value'] || raw_value[:value])
      when 'datetime'
        normalize_datetime_filter(raw_value['value'] || raw_value[:value])
      end

    return if value.nil?

    {
      definition: definition,
      operator: operator,
      value: value
    }
  end

  def normalized_filters
    return {} if raw_filters.blank?

    @normalized_filters ||= active_definitions.each_with_object({}) do |definition, result|
      if discrete_filter?(definition)
        values = normalize_values_for(definition)
        next if values.blank?

        result[definition.key] = {
          definition: definition,
          values: values
        }
      else
        advanced_filter = normalize_advanced_filter_for(definition)
        next if advanced_filter.blank?

        result[definition.key] = advanced_filter
      end
    end
  end

  def normalize_raw_filters(raw_filters)
    case raw_filters
    when ActionController::Parameters
      raw_filters.to_unsafe_h
    when Hash
      raw_filters
    else
      {}
    end
  end

  def normalize_boolean(value)
    case value
    when true, 'true', 1, '1'
      true
    when false, 'false', 0, '0'
      false
    else
      nil
    end
  end

  def normalize_number(value)
    return if value.blank?
    return value.to_f if value.is_a?(Numeric)

    Float(value)
  rescue ArgumentError, TypeError
    nil
  end

  def normalize_date_filter(value)
    return if value.blank?

    Date.iso8601(value.to_s)
  rescue Date::Error
    nil
  end

  def normalize_datetime_filter(value)
    return if value.blank?

    Time.zone.parse(value.to_s)
  end

  def date_value(raw_value)
    normalize_date_filter(raw_value)
  end

  def datetime_value(raw_value)
    return if raw_value.blank?

    Time.zone.parse(raw_value.to_s)
  end

  def value_present?(value)
    return true if value == false

    value.present?
  end

  def apply_to_relation(records)
    normalized_filters.reduce(records) do |scope, (key, config)|
      field_type = config[:definition].field_type

      if DISCRETE_FILTERABLE_FIELD_TYPES.include?(field_type)
        apply_discrete_filter_to_relation(scope, key, field_type, config[:values])
      else
        apply_advanced_filter_to_relation(scope, key, field_type, config[:operator], config[:value])
      end
    end
  end

  def apply_discrete_filter_to_relation(scope, key, field_type, values)
    return scope if values.blank?

    case field_type
    when 'checkbox'
      scope.where("#{json_text_expression(scope, key)} IN (?)", values.map { |value| value.to_s })
    when 'multiselect'
      scope.where(
        "EXISTS (SELECT 1 FROM jsonb_array_elements_text(COALESCE(#{json_value_expression(scope, key)}, '[]'::jsonb)) AS elem(value) WHERE elem.value IN (?))",
        values
      )
    else
      scope.where("#{json_text_expression(scope, key)} IN (?)", values)
    end
  end

  def apply_advanced_filter_to_relation(scope, key, field_type, operator, value)
    if operator == 'is_present'
      return apply_presence_filter_to_relation(scope, key, field_type, present: true)
    end

    if operator == 'is_not_present'
      return apply_presence_filter_to_relation(scope, key, field_type, present: false)
    end

    case field_type
    when *TEXT_FILTERABLE_FIELD_TYPES
      apply_text_filter_to_relation(scope, key, operator, value)
    when *NUMERIC_FILTERABLE_FIELD_TYPES
      apply_numeric_filter_to_relation(scope, key, operator, value)
    when 'date'
      apply_date_filter_to_relation(scope, key, operator, value)
    when 'datetime'
      apply_datetime_filter_to_relation(scope, key, operator, value)
    else
      scope.none
    end
  end

  def apply_presence_filter_to_relation(scope, key, field_type, present:)
    sql =
      if field_type == 'checkbox'
        "#{json_text_expression(scope, key)} IS NOT NULL"
      elsif field_type == 'multiselect'
        "jsonb_array_length(COALESCE(#{json_value_expression(scope, key)}, '[]'::jsonb)) > 0"
      else
        "NULLIF(BTRIM(#{json_text_expression(scope, key)}), '') IS NOT NULL"
      end

    present ? scope.where(sql) : scope.where("NOT (#{sql})")
  end

  def apply_text_filter_to_relation(scope, key, operator, value)
    expression = json_text_expression(scope, key)

    case operator
    when 'equals'
      scope.where("LOWER(#{expression}) = LOWER(?)", value.to_s)
    when 'contains'
      scope.where("LOWER(#{expression}) LIKE ?", "%#{value.to_s.downcase}%")
    else
      scope.none
    end
  end

  def apply_numeric_filter_to_relation(scope, key, operator, value)
    expression = safe_numeric_expression(scope, key)

    case operator
    when 'equals'
      scope.where("#{expression} = ?", value)
    when 'greater_than'
      scope.where("#{expression} > ?", value)
    when 'less_than'
      scope.where("#{expression} < ?", value)
    else
      scope.none
    end
  end

  def apply_date_filter_to_relation(scope, key, operator, value)
    expression = safe_date_expression(scope, key)

    case operator
    when 'on'
      scope.where("#{expression} = ?", value)
    when 'after'
      scope.where("#{expression} > ?", value)
    when 'before'
      scope.where("#{expression} < ?", value)
    else
      scope.none
    end
  end

  def apply_datetime_filter_to_relation(scope, key, operator, value)
    expression = safe_datetime_expression(scope, key)

    case operator
    when 'on'
      scope.where("#{expression} = ?", value)
    when 'after'
      scope.where("#{expression} > ?", value)
    when 'before'
      scope.where("#{expression} < ?", value)
    else
      scope.none
    end
  end

  def custom_attributes_column(scope)
    "#{scope.model.table_name}.custom_attributes"
  end

  def json_text_expression(scope, key)
    "#{custom_attributes_column(scope)} ->> #{scope.connection.quote(key)}"
  end

  def json_value_expression(scope, key)
    "#{custom_attributes_column(scope)} -> #{scope.connection.quote(key)}"
  end

  def trimmed_json_text_expression(scope, key)
    "NULLIF(BTRIM(#{json_text_expression(scope, key)}), '')"
  end

  def safe_numeric_expression(scope, key)
    expression = trimmed_json_text_expression(scope, key)
    <<~SQL.squish
      CASE
        WHEN #{expression} ~ '^(-|)[0-9]+(\\.[0-9]+){0,1}$'
        THEN (#{expression})::numeric
      END
    SQL
  end

  def safe_date_expression(scope, key)
    expression = trimmed_json_text_expression(scope, key)
    <<~SQL.squish
      CASE
        WHEN #{expression} ~ '^\\d{4}-\\d{2}-\\d{2}$'
        THEN (#{expression})::date
      END
    SQL
  end

  def safe_datetime_expression(scope, key)
    expression = trimmed_json_text_expression(scope, key)
    <<~SQL.squish
      CASE
        WHEN #{expression} ~ '^\\d{4}-\\d{2}-\\d{2}T'
        THEN (#{expression})::timestamptz
      END
    SQL
  end
end
