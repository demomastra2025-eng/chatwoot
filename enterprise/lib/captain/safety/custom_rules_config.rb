# frozen_string_literal: true

class Captain::Safety::CustomRulesConfig
  MAX_RULES = 20
  MAX_NAME_LENGTH = 120
  MAX_INSTRUCTION_LENGTH = 2000
  MAX_MESSAGE_LENGTH = 2000
  ID_PATTERN = /\A[A-Za-z0-9][A-Za-z0-9_-]{0,63}\z/
  NONE_ID = 'none'
  DIRECTIONS = %w[input output].freeze
  ACTIONS = %w[handoff block rewrite].freeze
  REQUIRED_FIELDS = %w[id name direction instruction action enabled].freeze
  OPTIONAL_FIELDS = %w[message].freeze
  ROOT_PATH = 'safety_settings.custom_rules'

  def self.errors(rules)
    new(rules).errors
  end

  def initialize(rules)
    @rules = rules
    @errors = []
    @ids = []
  end

  def errors
    return @errors if @validated

    @validated = true
    if !@rules.is_a?(Array)
      add_error(ROOT_PATH, 'invalid_type', 'must be an array')
    elsif @rules.size > MAX_RULES
      add_error(ROOT_PATH, 'too_many', "must contain at most #{MAX_RULES} rules")
    else
      @rules.each_with_index { |rule, index| validate_rule(rule, "#{ROOT_PATH}[#{index}]") }
    end
    @errors
  end

  private

  def validate_rule(raw_rule, path)
    return add_error(path, 'invalid_type', 'must be an object') unless raw_rule.is_a?(Hash)

    rule = raw_rule.stringify_keys
    if (rule.keys - REQUIRED_FIELDS - OPTIONAL_FIELDS).any?
      add_error(path, 'unknown_fields', 'contains unsupported fields')
    end
    (REQUIRED_FIELDS - rule.keys).each { |field| add_error("#{path}.#{field}", 'required', 'is required') }
    validate_id(rule['id'], "#{path}.id") if rule.key?('id')
    validate_string(rule, 'name', path, MAX_NAME_LENGTH, required: true)
    validate_string(rule, 'instruction', path, MAX_INSTRUCTION_LENGTH, required: true)
    validate_string(rule, 'message', path, MAX_MESSAGE_LENGTH, required: false)
    validate_actions(rule, path)
    validate_enabled(rule, path)
  end

  def validate_actions(rule, path)
    validate_enum(rule, 'direction', path, DIRECTIONS)
    validate_enum(rule, 'action', path, ACTIONS)
    if rule['action'] == 'rewrite' && rule['direction'] != 'output'
      add_error("#{path}.action", 'output_only', 'rewrite is allowed only for output rules')
    end
  end

  def validate_enabled(rule, path)
    return unless rule.key?('enabled')
    return if rule['enabled'].equal?(true) || rule['enabled'].equal?(false)

    add_error("#{path}.enabled", 'invalid_type', 'must be a boolean')
  end

  def validate_id(value, path)
    unless value.is_a?(String) && ID_PATTERN.match?(value) && value != NONE_ID
      add_error(path, 'invalid_id', 'must be a 1-64 character letter, digit, underscore or hyphen token other than none')
      return
    end
    add_error(path, 'duplicate_id', 'must be unique within custom rules') if @ids.include?(value)
    @ids << value
  end

  def validate_string(rule, field, path, maximum, required:)
    return unless rule.key?(field)

    value = rule[field]
    if !value.is_a?(String)
      add_error("#{path}.#{field}", 'invalid_type', 'must be a string')
    elsif required && value.strip.empty?
      add_error("#{path}.#{field}", 'blank', 'must not be blank')
    elsif value.length > maximum
      add_error("#{path}.#{field}", 'too_long', "must contain at most #{maximum} characters")
    end
  end

  def validate_enum(rule, field, path, values)
    return unless rule.key?(field)
    return if values.include?(rule[field])

    add_error("#{path}.#{field}", 'invalid_value', "must be one of #{values.join(', ')}")
  end

  def add_error(path, code, message)
    @errors << { path: path, code: code, message: message }
  end
end
