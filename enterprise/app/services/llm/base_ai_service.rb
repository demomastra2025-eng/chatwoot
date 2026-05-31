# frozen_string_literal: true

# Base service for LLM operations using RubyLLM.
# New features should inherit from this class.
class Llm::BaseAiService
  DEFAULT_MODEL = Llm::Config::DEFAULT_MODEL
  DEFAULT_TEMPERATURE = 1.0

  attr_reader :temperature

  def initialize
    Llm::Config.initialize!
    setup_temperature
  end

  def model
    @model ||= resolved_model
  end

  def chat(model: self.model, temperature: @temperature, thinking: nil)
    Llm::Runtime.build_chat(
      feature: llm_feature_key,
      account: llm_model_account,
      model: model,
      options: runtime_chat_options(model: model, temperature: temperature, thinking: thinking)
    )
  end

  def ask_chat(chat, content, observability: default_observability_payload)
    Llm::Runtime.ask(chat, content, **runtime_ask_kwargs(observability: observability))
  end

  private

  def apply_chat_features(chat, schema: nil, tools: [])
    Llm::CapabilityPolicy.ensure_chat_features_supported!(
      model: resolved_chat_model(chat),
      schema: schema,
      tools: tools,
      account: llm_model_account
    )

    chat = Llm::StructuredOutputPolicy.bind!(chat: chat, schema: schema) if schema.present?
    enforce_openrouter_tool_parameters!(chat, tools)
    Array(tools).each { |tool| chat.with_tool(tool) }
    chat
  end

  def enforce_openrouter_tool_parameters!(chat, tools)
    return if Array(tools).blank?

    Llm::OpenRouterRequestPolicy.require_parameters!(chat, account: llm_model_account)
  end

  def setup_temperature
    @temperature = DEFAULT_TEMPERATURE
  end

  def runtime_chat_options(model:, temperature:, thinking:)
    {
      temperature: temperature,
      thinking: thinking
    }.tap do |options|
      context = llm_context_for_model(model, llm_model_account)
      options[:context] = context if context.present?
    end
  end

  def runtime_ask_kwargs(observability:)
    account = llm_model_account
    { account: account, model: account.present? || observability.present? ? model : nil, observability: observability }
  end

  def llm_context_for_model(model_name, account)
    return if account.blank? || model_name.blank?

    provider = Llm::Config.provider_for_model(model_name, account: account)
    return if provider.blank?

    return unless Llm::Config.account_provider_available?(provider, account: account)

    runtime_api_key = Llm::Config.api_key(provider, account: account)
    runtime_api_base = Llm::Config.api_base(provider, account: account) if Llm::Config.custom_api_base_configured?(provider, account: account)
    return if runtime_api_key.blank? && runtime_api_base.blank?

    Llm::Config.context(
      model: model_name,
      provider: provider,
      api_key: runtime_api_key,
      api_base: runtime_api_base,
      account: account
    )
  end

  def llm_feature_key
    nil
  end

  def llm_model_account
    nil
  end

  def resolved_model
    Llm::Config.model_for(
      feature: llm_feature_key,
      account: llm_model_account,
      fallback: DEFAULT_MODEL
    )
  end

  def resolved_chat_model(chat)
    return model if model.present?

    chat_model = chat&.model
    return chat_model.id if chat_model.respond_to?(:id)
    return chat_model if chat_model.present?
  end

  def llm_thinking_options
    return nil if llm_feature_key.blank?

    Llm::RuntimePolicy.thinking_options(
      feature: llm_feature_key,
      account: llm_model_account,
      model: model
    )
  end

  def default_observability_payload
    instrumentation = default_instrumentation_params
    return {} if instrumentation.blank?

    instrumentation.merge(runtime_mode: self.class.name.underscore)
  end

  def default_instrumentation_params
    return {} unless respond_to?(:instrumentation_params, true)

    instrumentation_method = method(:instrumentation_params)
    return {} unless instrumentation_method.arity.zero?

    payload = instrumentation_method.call
    payload.is_a?(Hash) ? payload : {}
  rescue StandardError
    {}
  end
end
