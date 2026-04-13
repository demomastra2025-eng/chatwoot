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
    Llm::ChatClient.build(model: model, temperature: temperature, thinking: thinking)
  end

  def ask_chat(chat, content, observability: default_observability_payload)
    Llm::ChatClient.ask(chat, content, observability: observability)
  end

  private

  def apply_chat_features(chat, schema: nil, tools: [])
    Llm::CapabilityPolicy.ensure_chat_features_supported!(model: resolved_chat_model(chat), schema:, tools:)

    chat = Llm::StructuredOutputPolicy.bind!(chat:, schema:) if schema.present?
    Array(tools).each { |tool| chat.with_tool(tool) }
    chat
  end

  def setup_temperature
    @temperature = DEFAULT_TEMPERATURE
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
    chat_model = chat&.model
    return chat_model.id if chat_model.respond_to?(:id)
    return chat_model if chat_model.present?

    model
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
