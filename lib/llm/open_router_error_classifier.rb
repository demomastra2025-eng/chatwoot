# frozen_string_literal: true

class Llm::OpenRouterErrorClassifier
  Result = Struct.new(:category, :retryable, :retry_after_seconds, keyword_init: true) do
    def to_h
      {
        category: category,
        retryable: retryable,
        retry_after_seconds: retry_after_seconds
      }.compact
    end
  end

  RETRYABLE_CATEGORIES = %w[
    rate_limited retry_after model_unavailable provider_error provider_invalid_response
    no_content_generated timeout network_error
  ].freeze
  CATEGORY_CHECKS = {
    'configuration_missing' => :configuration_missing?,
    'invalid_api_key' => :invalid_api_key?,
    'insufficient_credits' => :insufficient_credits?,
    'rate_limited' => :rate_limited?,
    'retry_after' => :retry_after?,
    'routing_requirements_unsatisfied' => :routing_requirements_unsatisfied?,
    'context_length_exceeded' => :context_length_exceeded?,
    'schema_invalid' => :schema_invalid?,
    'guardrail_blocked' => :guardrail_blocked?,
    'moderation_flagged' => :moderation_flagged?,
    'no_content_generated' => :no_content_generated?,
    'timeout' => :timeout_error?,
    'network_error' => :network_error?,
    'model_unavailable' => :model_unavailable?,
    'provider_invalid_response' => :provider_invalid_response?,
    'provider_error' => :provider_error?
  }.freeze

  class << self
    def classify(error)
      new(error).classify
    end
  end

  def initialize(error)
    @error = error
  end

  def classify
    category = classify_category
    Result.new(
      category: category,
      retryable: RETRYABLE_CATEGORIES.include?(category),
      retry_after_seconds: retry_after_seconds
    )
  end

  private

  attr_reader :error

  def classify_category
    CATEGORY_CHECKS.each do |category, predicate|
      return category if send(predicate)
    end

    'unknown'
  end

  def configuration_missing?
    class_name.include?('ConfigurationError') || message.match?(/not configured|missing configuration|missing api key/i)
  end

  def invalid_api_key?
    class_name.match?(/Unauthorized|Authentication/i) || message.match?(/invalid api key|unauthorized|401/i)
  end

  def insufficient_credits?
    message.match?(/insufficient credits|credits exhausted|no credits/i)
  end

  def rate_limited?
    class_name.include?('RateLimit') || message.match?(/rate limit|429|quota exceeded/i)
  end

  def retry_after?
    retry_after_seconds.present?
  end

  def routing_requirements_unsatisfied?
    message.match?(/no endpoints|requested parameters|required parameters|require_parameters|unsupported parameter/i)
  end

  def context_length_exceeded?
    message.match?(/context length|maximum context|too many tokens|context.*exceeded/i)
  end

  def schema_invalid?
    message.match?(/schema invalid|invalid schema|response_format|json schema/i)
  end

  def guardrail_blocked?
    message.match?(/guardrail|policy blocked|blocked by policy/i)
  end

  def moderation_flagged?
    message.match?(/moderation|flagged/i)
  end

  def no_content_generated?
    message.match?(/no content|blank response|empty response|did not generate/i)
  end

  def timeout_error?
    class_name.match?(/Timeout|OpenTimeout|ReadTimeout/) || message.match?(/timed out|timeout/i)
  end

  def network_error?
    message.match?(/getaddrinfo|connection refused|connection reset|network|socket/i)
  end

  def model_unavailable?
    message.match?(/model.*not found|model.*unavailable|404/i)
  end

  def provider_invalid_response?
    message.match?(/invalid json|invalid response|did not include|malformed/i)
  end

  def provider_error?
    message.match?(/provider error|bad gateway|502|503|504|5\d\d|upstream/i)
  end

  def retry_after_seconds
    retry_after_from_error || retry_after_from_message
  end

  def retry_after_from_error
    return unless error.respond_to?(:retry_after)

    integer_value(error.retry_after)
  end

  def retry_after_from_message
    match = message.match(/retry[-\s]?after[:\s]+(\d+)/i) || message.match(/retry after (\d+) seconds?/i)
    integer_value(match&.[](1))
  end

  def integer_value(value)
    return if value.blank?

    value.to_i.then { |integer| integer.positive? ? integer : nil }
  end

  def class_name
    error.class.name.to_s
  end

  def message
    @message ||= error.respond_to?(:message) ? error.message.to_s : error.to_s
  end
end
