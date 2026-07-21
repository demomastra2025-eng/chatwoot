module Telephony::RoutingPolicy::CallDurationLimit
  extend ActiveSupport::Concern

  DEFAULT_MAX_CALL_DURATION_SECONDS = 30.minutes.to_i
  MIN_MAX_CALL_DURATION_SECONDS = 5.minutes.to_i
  MAX_MAX_CALL_DURATION_SECONDS = 4.hours.to_i

  included do
    validate :validate_max_call_duration_seconds
  end

  def max_call_duration_seconds=(value)
    self.settings = settings.to_h.deep_stringify_keys.merge('max_call_duration_seconds' => value)
  end

  def max_call_duration_seconds
    value = parsed_max_call_duration_seconds
    return DEFAULT_MAX_CALL_DURATION_SECONDS if value.blank?

    value.clamp(MIN_MAX_CALL_DURATION_SECONDS, MAX_MAX_CALL_DURATION_SECONDS)
  end

  private

  def parsed_max_call_duration_seconds
    raw_value = settings.to_h['max_call_duration_seconds']
    return if raw_value.blank?

    Integer(raw_value.to_s, 10)
  rescue ArgumentError, TypeError
    nil
  end

  def validate_max_call_duration_seconds
    raw_value = settings.to_h['max_call_duration_seconds']
    return if raw_value.blank?

    value = parsed_max_call_duration_seconds
    return if value&.between?(MIN_MAX_CALL_DURATION_SECONDS, MAX_MAX_CALL_DURATION_SECONDS)

    errors.add(
      :max_call_duration_seconds,
      "must be between #{MIN_MAX_CALL_DURATION_SECONDS} and #{MAX_MAX_CALL_DURATION_SECONDS}"
    )
  end
end
