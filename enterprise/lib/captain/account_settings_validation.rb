# frozen_string_literal: true

class Captain::AccountSettingsValidation
  BOOL = [true, false].freeze
  REASON_KEYS = %w[id label enabled builtin].freeze

  def initialize(defaults)
    @defaults = defaults
  end

  def errors(patch)
    return [error('settings', 'invalid_type', 'must be an object')] unless patch.is_a?(Hash)

    patch.flat_map { |section, fields| section_errors(section, fields) }
  end

  private

  def section_errors(section, fields)
    return [error(section, 'invalid_section', 'is not a writable settings section')] if section == 'availability' || !@defaults[section].is_a?(Hash)
    return [error(section, 'invalid_type', 'must be an object')] unless fields.is_a?(Hash)

    fields.flat_map { |key, value| field_errors(section, key, value) }
  end

  def field_errors(section, key, value)
    path = "#{section}.#{key}"
    return [error(path, 'unknown_field', 'is not a setting')] unless @defaults[section].key?(key)

    return boolean_errors(value, path) if Captain::AccountSettings::BOOLEAN_FIELDS.fetch(section, []).include?(key)
    if section == 'routing' && key == 'auto_reply_mode'
      return CaptainInbox::AUTO_REPLY_MODES.include?(value) ? [] : [error(path, 'invalid_value', 'must be a reply time mode')]
    end
    return structured_errors(key, value, path) if structured_field?(key)

    Captain::AccountSettings::ACTION_FROM_API.key?(value) ? [] : [error(path, 'invalid_value', 'must be block, flag, or off')]
  end

  def structured_field?(key)
    Captain::AccountSettings::MESSAGE_FIELDS.include?(key) || Captain::AccountSettings::REASON_FIELDS.include?(key) ||
      %w[custom_rules message_collapse_window_seconds].include?(key)
  end

  def structured_errors(key, value, path)
    return message_errors(value, path) if Captain::AccountSettings::MESSAGE_FIELDS.include?(key)
    return reason_errors(value, path) if Captain::AccountSettings::REASON_FIELDS.include?(key)
    return rule_errors(value) if key == 'custom_rules'

    integer_errors(value, path)
  end

  def boolean_errors(value, path)
    BOOL.include?(value) ? [] : [error(path, 'invalid_type', 'must be a boolean')]
  end

  def message_errors(value, path)
    return [error(path, 'invalid_type', 'must be an object')] unless value.is_a?(Hash)

    value.filter_map { |key, item| message_field_error("#{path}.#{key}", key, item) }
  end

  def message_field_error(path, key, item)
    return error(path, 'too_long', 'is too long') if key == 'instruction' && instruction_too_long?(item)

    error(path, 'invalid_value', 'has an invalid value') unless message_field_valid?(key, item)
  end

  def message_field_valid?(key, item)
    case key
    when 'enabled' then BOOL.include?(item)
    when 'mode' then Captain::AccountSettings::MESSAGE_MODE_FROM_API.key?(item)
    when 'text', 'instruction' then item.is_a?(String)
    else false
    end
  end

  def instruction_too_long?(item)
    item.is_a?(String) && item.length > Captain::AccountSettings::MESSAGE_INSTRUCTION_MAX_LENGTH
  end

  def integer_errors(value, path)
    value.is_a?(Integer) && value >= 0 ? [] : [error(path, 'invalid_value', 'must be a non-negative integer')]
  end

  def reason_errors(value, path)
    return [error(path, 'invalid_type', 'must be an array')] unless value.is_a?(Array)

    errors = []
    errors << error(path, 'too_many', 'has too many reasons') if value.size > Captain::OutcomeReasonConfig::MAX_REASONS_PER_TYPE
    ids = []
    value.each_with_index do |reason, index|
      unless valid_reason?(reason, path) && ids.exclude?(reason['id'])
        errors << error("#{path}[#{index}]", 'invalid_reason', 'has invalid or duplicate reason fields')
      end
      ids << reason['id'] if reason.is_a?(Hash)
    end
    errors
  end

  def valid_reason?(reason, path)
    reason.is_a?(Hash) && (reason.keys - REASON_KEYS).empty? &&
      valid_reason_text?(reason) && BOOL.include?(reason['enabled']) && valid_reason_flags?(reason, path)
  end

  def valid_reason_flags?(reason, path)
    type = path.start_with?('handoff.handoff_reasons') ? 'handoff' : 'completion'
    builtin = Captain::OutcomeReasonConfig::BUILTIN_IDS.fetch(type).include?(reason['id'])
    BOOL.include?(reason['builtin']) && reason['builtin'] == builtin &&
      (%w[other faq_no_answer].exclude?(reason['id']) || reason['enabled'])
  end

  def valid_reason_text?(reason)
    reason['id'].is_a?(String) && Captain::OutcomeReasonConfig::ID_PATTERN.match?(reason['id']) &&
      reason['label'].is_a?(String) && reason['label'].present? &&
      reason['label'].length <= Captain::OutcomeReasonConfig::MAX_LABEL_LENGTH
  end

  def rule_errors(value)
    return [error('safety.custom_rules', 'invalid_type', 'must be an array')] unless value.is_a?(Array)

    converted = value.map do |rule|
      next rule unless rule.is_a?(Hash)

      # Only the API spellings are accepted. A value left as it was sent would pass for the internal spelling
      # (input, output, block, rewrite), be stored as is and make Captain::AccountSettings#runtime_rules fail.
      rule.merge('direction' => Captain::AccountSettings::RULE_DIRECTION_FROM_API[rule['direction']],
                 'action' => Captain::AccountSettings::RULE_ACTION_FROM_API[rule['action']])
    end
    Captain::Safety::CustomRulesConfig.errors(converted).map do |violation|
      error(violation[:path].sub('safety_settings', 'safety'), violation[:code], violation[:message])
    end
  end

  def error(field, code, message)
    { field: field, code: code, message: I18n.t("captain.account_settings.errors.#{code}", default: message) }
  end
end
