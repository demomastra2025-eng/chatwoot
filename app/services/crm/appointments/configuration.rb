class Crm::Appointments::Configuration
  DEFAULTS = {
    'enabled' => false,
    'cardinality' => 'request',
    'auto_create_from_calendar' => false,
    'auto_create_from_medelement' => false,
    'manual_stage_change' => 'continue',
    'success_mode' => 'manual',
    'rules' => []
  }.freeze
  SCOPES = %w[any all selected nearest].freeze
  CONDITIONS = %w[provider_confirmed patient_confirmed scheduled attended cancelled no_show today tomorrow past future].freeze
  SUCCESS_MODES = %w[manual any_attended selected_attended all_required_attended].freeze
  SOURCE_KEYS = %w[auto_create_from_calendar auto_create_from_medelement].freeze

  def self.for(pipeline)
    DEFAULTS.deep_dup.merge(pipeline.appointment_automation.to_h.deep_stringify_keys)
  end

  def self.validate(pipeline)
    config = self.for(pipeline)
    errors = []
    errors << 'cardinality must be request or appointment' unless config['cardinality'].in?(%w[request appointment])
    errors << 'manual_stage_change must be continue or pause' unless config['manual_stage_change'].in?(%w[continue pause])
    errors << 'success_mode is invalid' unless config['success_mode'].in?(SUCCESS_MODES)
    %w[enabled auto_create_from_calendar auto_create_from_medelement].each do |key|
      errors << "#{key} must be boolean" unless [true, false].include?(config[key])
    end
    rules = config['rules']
    return errors + ['rules must be an array with at most 50 entries'] unless rules.is_a?(Array) && rules.length <= 50

    rules.each_with_index { |rule, index| errors.concat(validate_rule(pipeline, rule, index)) }
    errors
  end

  def self.validate_rule(pipeline, rule, index)
    return ["rule #{index + 1} must be an object"] unless rule.is_a?(Hash)

    rule = rule.deep_stringify_keys
    conditions = Array(rule['conditions'])
    errors = []
    stage = pipeline.stages.active.find_by(id: rule['stage_id']) if rule['stage_id'].present?
    errors << "rule #{index + 1} requires an active stage in this pipeline" unless stage
    errors << "rule #{index + 1} has an invalid scope" unless rule['scope'].in?(SCOPES)
    errors << "rule #{index + 1} requires valid conditions" if conditions.empty? || (conditions - CONDITIONS).any?
    if stage
      errors << "rule #{index + 1} has invalid closing reasons" if stage.invalid_closing_reasons(Array(rule['closing_reasons'])).any?
      errors << "rule #{index + 1} requires closing reasons" if stage.closing_reason_required? && Array(rule['closing_reasons']).empty?
      errors << "rule #{index + 1} has an invalid transition reason" if stage.invalid_transition_reason(rule['transition_reason']).any?
      errors << "rule #{index + 1} requires a transition reason" if stage.transition_reason_required? && rule['transition_reason'].blank?
    end
    errors
  end
  private_class_method :validate_rule
end
