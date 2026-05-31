# frozen_string_literal: true

class Llm::OpenRouterRetryPolicy
  DEFAULT_MAX_ATTEMPTS = 2
  IMMEDIATE_RETRY_CATEGORIES = %w[
    no_content_generated provider_invalid_response provider_error model_unavailable timeout network_error
  ].freeze

  Decision = Struct.new(:retryable, :reason, :category, :retry_after_seconds, :max_attempts, keyword_init: true) do
    def retryable?
      retryable == true
    end

    def to_h
      {
        retryable: retryable,
        reason: reason,
        category: category,
        retry_after_seconds: retry_after_seconds,
        max_attempts: max_attempts
      }.compact
    end
  end

  def initialize(attributes = {})
    @provider = attributes[:provider].to_s.presence
    @model = attributes[:model].to_s.presence
    @feature = attributes[:feature].to_s.presence
    @account = attributes[:account]
    @tools = Array(attributes[:tools])
    @stream = attributes[:stream] == true
    @max_attempts = (attributes[:max_attempts] || DEFAULT_MAX_ATTEMPTS).to_i
  end

  def retryable_error?(error, attempt:)
    classification = Llm::OpenRouterErrorClassifier.classify(error)
    return blocked(:not_openrouter, classification, attempt) unless openrouter?
    return blocked(:attempts_exhausted, classification, attempt) unless attempts_remaining?(attempt)
    return blocked(:streaming_request, classification, attempt) if stream?
    return blocked(:unsafe_tool_flow, classification, attempt) if unsafe_tool_flow?
    return blocked(classification.category, classification, attempt) unless immediately_retryable?(classification)

    allowed(classification.category, classification)
  end

  def retryable_response?(response, attempt:)
    classification = Llm::OpenRouterErrorClassifier::Result.new(
      category: 'no_content_generated',
      retryable: true,
      retry_after_seconds: nil
    )
    return blocked(:not_openrouter, classification, attempt) unless openrouter?
    return blocked(:attempts_exhausted, classification, attempt) unless attempts_remaining?(attempt)
    return blocked(:streaming_request, classification, attempt) if stream?
    return blocked(:unsafe_tool_flow, classification, attempt) if unsafe_tool_flow?
    return blocked(:response_present, classification, attempt) unless blank_final_response?(response)

    allowed('blank_response', classification)
  end

  def max_attempts
    [@max_attempts, 1].max
  end

  private

  attr_reader :provider, :model, :feature, :account, :tools

  def openrouter?
    provider == 'openrouter' || provider_for_model == 'openrouter'
  end

  def provider_for_model
    return if model.blank?

    Llm::Models.provider_for(model, account: account)
  rescue StandardError
    nil
  end

  def attempts_remaining?(attempt)
    attempt.to_i < max_attempts
  end

  def stream?
    @stream
  end

  def unsafe_tool_flow?
    tools.any? { |tool| Llm::ToolRiskPolicy.mutating?(tool) }
  end

  def immediately_retryable?(classification)
    classification.retryable == true && IMMEDIATE_RETRY_CATEGORIES.include?(classification.category)
  end

  def blank_final_response?(response)
    return true if response.blank?
    return false if halt_result?(response)
    return false if response.respond_to?(:tool_call?) && response.tool_call?
    return false unless response.respond_to?(:content)

    response.content.blank?
  end

  def halt_result?(response)
    defined?(RubyLLM::Tool::Halt) && response.is_a?(RubyLLM::Tool::Halt)
  end

  def allowed(reason, classification)
    Decision.new(
      retryable: true,
      reason: reason,
      category: classification.category,
      retry_after_seconds: classification.retry_after_seconds,
      max_attempts: max_attempts
    )
  end

  def blocked(reason, classification, _attempt)
    Decision.new(
      retryable: false,
      reason: reason.to_s,
      category: classification.category,
      retry_after_seconds: classification.retry_after_seconds,
      max_attempts: max_attempts
    )
  end
end
