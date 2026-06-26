class Conversations::StatusReasonConfig
  VALID_STATUSES = %w[open resolved pending snoozed].freeze
  SETTINGS_KEY = 'conversation_status_reason_config'.freeze

  class Error < StandardError
    attr_reader :code, :status, :details

    def initialize(code:, message:, status: :unprocessable_content, details: nil)
      super(message)
      @code = code
      @status = status
      @details = details
    end
  end

  def self.normalize_settings(raw_config)
    config = raw_config.respond_to?(:to_unsafe_h) ? raw_config.to_unsafe_h : raw_config
    config = config.to_h.with_indifferent_access if config.respond_to?(:to_h)
    config = {} unless config.is_a?(Hash)

    VALID_STATUSES.index_with do |status|
      raw_status_config = (config[status] || {}).to_h.with_indifferent_access
      {
        'options' => normalize_reason_values(raw_status_config[:options]),
        'required' => ActiveModel::Type::Boolean.new.cast(raw_status_config[:required]) || false
      }
    end
  end

  def self.normalize_reason_values(values)
    Array(values).filter_map do |value|
      reason = if value.respond_to?(:key?)
                 value[:label] || value['label'] || value[:value] || value['value']
               else
                 value
               end

      reason.to_s.strip.presence
    end.uniq
  end

  def initialize(account)
    @account = account
  end

  def for_status(status)
    normalized_settings[canonical_status!(status)]
  end

  def configured_for_status?(status)
    config = for_status(status)
    config['required'] || config['options'].present?
  end

  def canonical_reason(status, reason)
    status = canonical_status!(status)
    submitted_reason = self.class.normalize_reason_values([reason]).first
    return if submitted_reason.blank?

    for_status(status)['options'].find { |option| option.casecmp?(submitted_reason) }
  end

  def resolve_reason!(status, reason, enforce_required: true)
    status = canonical_status!(status)
    config = for_status(status)
    submitted_reason = self.class.normalize_reason_values([reason]).first

    raise_missing_reason!(status, config) if enforce_required && config['required'] && submitted_reason.blank?
    return if submitted_reason.blank?

    canonical_reason = canonical_reason(status, submitted_reason)
    raise_invalid_reason!(status, submitted_reason, config) if canonical_reason.blank?

    canonical_reason
  end

  def normalized_settings
    @normalized_settings ||= self.class.normalize_settings(@account.settings&.fetch(SETTINGS_KEY, nil))
  end

  private

  def canonical_status!(status)
    status = status.to_s.strip
    return status if VALID_STATUSES.include?(status)

    raise Error.new(
      code: 'CONVERSATION_STATUS_INVALID',
      message: "Invalid conversation status: #{status}",
      status: :unprocessable_content,
      details: { allowed_statuses: VALID_STATUSES }
    )
  end

  def raise_missing_reason!(status, config)
    raise Error.new(
      code: 'CONVERSATION_STATUS_REASON_REQUIRED',
      message: "Select a reason before moving the conversation to #{status}.",
      status: :unprocessable_content,
      details: {
        status: status,
        reason_options: config['options']
      }
    )
  end

  def raise_invalid_reason!(status, reason, config)
    raise Error.new(
      code: 'CONVERSATION_STATUS_REASON_INVALID',
      message: "Conversation status reason is not configured for #{status}: #{reason}.",
      status: :unprocessable_content,
      details: {
        status: status,
        invalid_reason: reason,
        reason_options: config['options']
      }
    )
  end
end
