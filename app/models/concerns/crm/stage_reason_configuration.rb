module Crm::StageReasonConfiguration
  extend ActiveSupport::Concern

  class_methods do
    def normalize_closing_reason_values(values)
      Array(values).filter_map do |value|
        reason = if value.respond_to?(:key?)
                   value[:label] || value['label'] || value[:value] || value['value']
                 else
                   value
                 end

        reason.to_s.strip.presence
      end.uniq
    end
  end

  def canonical_closing_reasons(values)
    normalized_values = self.class.normalize_closing_reason_values(values)
    return [] if normalized_values.blank?

    options_by_key = closing_reason_options.index_by { |reason| reason.to_s.downcase }
    normalized_values.filter_map do |reason|
      options_by_key[reason.to_s.downcase]
    end.uniq
  end

  def invalid_closing_reasons(values)
    normalized_values = self.class.normalize_closing_reason_values(values)
    canonical_values = canonical_closing_reasons(normalized_values)

    normalized_values.reject do |reason|
      canonical_values.any? { |canonical_reason| canonical_reason.casecmp?(reason) }
    end
  end

  def canonical_transition_reason(value)
    reason = self.class.normalize_closing_reason_values([value]).first
    return if reason.blank?

    options_by_key = transition_reason_options.index_by { |option| option.to_s.downcase }
    options_by_key[reason.to_s.downcase]
  end

  def invalid_transition_reason(value)
    reason = self.class.normalize_closing_reason_values([value]).first
    return [] if reason.blank?
    return [] if canonical_transition_reason(reason).present?

    [reason]
  end

  private

  def normalize_closing_reason_config
    self.closing_reason_options = self.class.normalize_closing_reason_values(closing_reason_options)

    return if terminal_outcome?

    self.closing_reason_options = []
    self.closing_reason_required = false
  end

  def normalize_transition_reason_config
    self.transition_reason_options = self.class.normalize_closing_reason_values(transition_reason_options)

    return if outcome_open?

    self.transition_reason_options = []
    self.transition_reason_required = false
  end

  def closing_reason_required_requires_options
    return unless terminal_outcome?
    return unless closing_reason_required?
    return if closing_reason_options.present?

    errors.add(:closing_reason_options, 'must include at least one reason when required')
  end

  def transition_reason_required_requires_options
    return unless outcome_open?
    return unless transition_reason_required?
    return if transition_reason_options.present?

    errors.add(:transition_reason_options, 'must include at least one reason when required')
  end
end
