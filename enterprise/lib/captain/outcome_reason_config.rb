class Captain::OutcomeReasonConfig
  TYPES = %w[completion handoff].freeze
  MAX_REASONS_PER_TYPE = 20
  MAX_LABEL_LENGTH = 255
  DEFAULT_OTHER_LABEL = 'Other'.freeze
  ID_PATTERN = /\A[a-z0-9][a-z0-9_-]{0,63}\z/

  def self.normalize_settings(raw_settings)
    settings = raw_settings.respond_to?(:to_unsafe_h) ? raw_settings.to_unsafe_h : raw_settings
    settings = settings.to_h.deep_stringify_keys if settings.respond_to?(:to_h)
    settings = {} unless settings.is_a?(Hash)

    normalized = TYPES.index_with do |type|
      reason_key = "#{type}_reasons"
      normalize_reasons(settings[reason_key], configured: settings.key?(reason_key))
    end
    normalized.transform_keys { |type| "#{type}_reasons" }
  end

  def self.normalize_reasons(raw_reasons, configured:)
    return [] unless configured

    normalized = Array(raw_reasons).first(MAX_REASONS_PER_TYPE).filter_map { |reason| normalize_reason(reason) }
    normalized = normalized.uniq { |reason| reason['id'] }
    ensure_other_fallback(normalized)
  end

  def self.normalize_reason(raw_reason)
    reason = raw_reason.respond_to?(:to_h) ? raw_reason.to_h.deep_stringify_keys : {}
    id = reason['id'].to_s.strip
    label = reason['label'].to_s.squish.truncate(MAX_LABEL_LENGTH)
    return if id !~ ID_PATTERN || label.blank?

    active = reason.key?('active') ? [false, nil, 0, '0', 'false'].exclude?(reason['active']) : true
    { 'id' => id, 'label' => label, 'active' => active }
  end

  def self.ensure_other_fallback(normalized)
    other = normalized.find { |reason| reason['id'] == 'other' }
    if other
      other['active'] = true
      return normalized
    end

    fallback = { 'id' => 'other', 'label' => DEFAULT_OTHER_LABEL, 'active' => true }
    normalized.first(MAX_REASONS_PER_TYPE - 1) << fallback
  end
  private_class_method :normalize_reason, :ensure_other_fallback

  def initialize(assistant)
    @assistant = assistant
  end

  def normalized_settings
    @normalized_settings ||= self.class.normalize_settings(
      assistant.config.to_h.deep_stringify_keys['outcome_reason_settings']
    )
  end

  def reasons(type)
    normalized_settings.fetch(reason_key(type)).select { |reason| reason['active'] }
  end

  def configured?(type)
    reasons(type).present?
  end

  def resolve(type, candidate = nil)
    configured_reasons = reasons(type)
    return if configured_reasons.empty?

    candidate_id = candidate.to_s.strip
    match = configured_reasons.find { |reason| reason['id'] == candidate_id }
    return match if match

    configured_reasons.find { |reason| reason['id'] == 'other' }
  end

  def explanation_required?(type, candidate:, explanation:)
    reason = resolve(type, candidate)
    return false unless reason&.fetch('id') == 'other'

    normalized_explanation = explanation.to_s.squish
    return true if normalized_explanation.blank?

    normalized_explanation.downcase.in?([reason['id'].downcase, reason['label'].downcase])
  end

  def prompt_context
    TYPES.index_with do |type|
      reasons(type).map { |reason| reason.slice('id', 'label') }
    end
  end

  def transition_options(type, reason, explanation: nil)
    return {} if reason.blank?
    if explanation_required?(type, candidate: reason['id'], explanation: explanation)
      raise ArgumentError, 'A specific outcome explanation is required'
    end

    metadata = {
      outcome_reason_id: reason['id'],
      outcome_reason_type: canonical_type(type),
      assistant_id: assistant.id
    }
    metadata[:outcome_reason_explanation] = explanation.to_s.squish.truncate(1000) if explanation.present?

    {
      audit: {
        reason_override: reason['label'],
        metadata: metadata
      }
    }
  end

  private

  attr_reader :assistant

  def reason_key(type)
    "#{canonical_type(type)}_reasons"
  end

  def canonical_type(type)
    value = type.to_s
    return value if TYPES.include?(value)

    raise ArgumentError, "Outcome reason type must be one of: #{TYPES.join(', ')}"
  end
end
