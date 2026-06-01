# frozen_string_literal: true

class Llm::OpenRouterContextTransformPolicy
  CHARS_PER_TOKEN_ESTIMATE = 4.0
  SOFT_CONTEXT_LIMIT_RATIO = 0.85
  OPENROUTER_DEFAULT_COMPRESSION_CONTEXT_LIMIT = 8_192
  CONTEXT_COMPRESSION_PLUGIN_ID = 'context-compression'

  Plan = Struct.new(
    :status,
    :plugin,
    :estimated_tokens,
    :context_limit,
    :soft_context_limit,
    :policy,
    :reason,
    keyword_init: true
  ) do
    def plugin?
      plugin.present?
    end

    def applied?
      status == 'applied'
    end

    def to_metadata
      {
        openrouter_context_transform_status: status,
        openrouter_context_transform_policy: policy,
        openrouter_context_transform_reason: reason,
        openrouter_context_estimated_tokens: estimated_tokens,
        openrouter_context_limit: context_limit,
        openrouter_context_soft_limit: soft_context_limit
      }.compact
    end
  end

  class << self
    def call(messages:, model:, account: nil, policy: nil)
      new(messages: messages, model: model, account: account, policy: policy).call
    end
  end

  def initialize(messages:, model:, account:, policy:)
    @messages = Array(messages)
    @model = model.to_s.presence
    @account = account
    @policy = policy.to_s.presence || 'disabled'
  end

  def call
    return plan(status: 'disabled', reason: 'policy_disabled') unless @policy == 'overflow_only'
    return plan(status: 'skipped', reason: 'no_messages') if @messages.blank?
    return plan(status: 'skipped', reason: 'context_unknown') if context_limit.blank?

    return applied_plan if estimated_tokens > soft_context_limit

    return disabled_default_plan if context_limit <= OPENROUTER_DEFAULT_COMPRESSION_CONTEXT_LIMIT

    plan(status: 'skipped', reason: 'within_context')
  end

  private

  def applied_plan
    plan(
      status: 'applied',
      reason: 'estimated_tokens_exceed_soft_context_limit',
      plugin: { id: CONTEXT_COMPRESSION_PLUGIN_ID, mode: 'overflow_only' }
    )
  end

  def disabled_default_plan
    plan(
      status: 'disabled_default',
      reason: 'prevent_hidden_openrouter_default_for_small_context',
      plugin: { id: CONTEXT_COMPRESSION_PLUGIN_ID, enabled: false }
    )
  end

  def plan(status:, reason:, plugin: nil)
    Plan.new(
      status: status,
      plugin: plugin,
      estimated_tokens: estimated_tokens,
      context_limit: context_limit,
      soft_context_limit: soft_context_limit,
      policy: @policy,
      reason: reason
    )
  end

  def estimated_tokens
    @estimated_tokens ||= (estimated_characters / CHARS_PER_TOKEN_ESTIMATE).ceil
  end

  def estimated_characters
    @messages.sum { |message| message_text(message).length }
  end

  def message_text(message)
    return message.to_s unless message.respond_to?(:[])

    content = message[:content] || message['content']
    text_content(content)
  end

  def text_content(content)
    case content
    when Array
      content.map { |entry| text_content(entry) }.join("\n")
    when Hash
      hash = content.with_indifferent_access
      hash[:text].presence || hash[:content].presence || hash[:input].presence || hash.to_json
    else
      content.to_s
    end
  end

  def context_limit
    @context_limit ||= begin
      value = model_config&.fetch('context_length', nil).to_i
      value.positive? ? value : nil
    end
  end

  def soft_context_limit
    return if context_limit.blank?

    (context_limit * SOFT_CONTEXT_LIMIT_RATIO).floor
  end

  def model_config
    return if @model.blank?

    Llm::Models.model_config(@model, account: @account)
  end
end
