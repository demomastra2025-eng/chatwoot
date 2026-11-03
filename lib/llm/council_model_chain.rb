# frozen_string_literal: true

require 'timeout'

# Council transforms have a platform-ordered chain. Each attempt builds a fresh chat with one explicit model, so OpenRouter's
# three-model wire limit cannot clip the fourth choice or reorder the chain by provider price/latency. The caller keeps one
# deadline around the entire chain and validates its domain result inside the block; nil/blank results try the next model.
class Llm::CouncilModelChain
  FEATURES = %w[council_split council_edit].freeze
  TERMINAL_ERRORS = [Timeout::Error, RubyLLM::ForbiddenError, RubyLLM::UnauthorizedError, RubyLLM::PaymentRequiredError].freeze
  TRANSPORT_ERRORS = [RubyLLM::Error, Faraday::Error, IOError, SocketError].freeze
  AVAILABILITY_ERRORS = [RubyLLM::OverloadedError, RubyLLM::RateLimitError, RubyLLM::ServerError, RubyLLM::ServiceUnavailableError].freeze

  def initialize(feature:, model:, account:, runtime_preferences: nil)
    @feature = feature.to_s
    raise ArgumentError, 'Not a council transform' unless FEATURES.include?(@feature)

    @model = model
    @account = account
    @runtime_preferences = runtime_preferences
  end

  def call
    attempts = models
    result = nil
    attempts.each_with_index do |model, index|
      result = yield model
      return result if result.present?
    rescue StandardError => e
      raise unless recoverable?(e) && index < attempts.size - 1

      Rails.logger.warn("[LLM][CouncilModelChain] fallback feature=#{@feature} model=#{model} error_class=#{e.class.name}")
    end
    result
  end

  def models
    profile = Llm::OpenRouterRoutingProfile.for(
      feature: @feature, model: @model, account: @account, runtime_preferences: @runtime_preferences
    )
    fallbacks = profile.model_fallbacks_allowed? ? Llm::Models.features.fetch(@feature).fetch('fallbacks', []) : []
    ([@model] + fallbacks).compact_blank.map { |model| Llm::Models.canonical_model_name(model) }.uniq
  end

  private

  def recoverable?(error)
    # Timeout.timeout belongs to the whole transform. Authentication, consent/privacy, provider refusals and budget blocks
    # must never select another provider/model; only malformed output and classified upstream availability failures may do so.
    return false if TERMINAL_ERRORS.any? { |type| error.is_a?(type) }
    return true if error.is_a?(Llm::StructuredOutputPolicy::InvalidStructuredOutputError)
    return false unless TRANSPORT_ERRORS.any? { |type| error.is_a?(type) }

    classification = Llm::OpenRouterErrorClassifier.classify(error)
    classification.retryable == true || unclassified_availability_error?(error, classification)
  end

  def unclassified_availability_error?(error, classification)
    # RubyLLM keeps the HTTP status in its exception type, even when a provider's message omits "503"/"upstream".
    classification.category == 'unknown' && AVAILABILITY_ERRORS.any? { |type| error.is_a?(type) }
  end
end
