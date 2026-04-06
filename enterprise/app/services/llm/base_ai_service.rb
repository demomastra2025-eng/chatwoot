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

  def ask_chat(chat, content)
    Llm::ChatClient.ask(chat, content)
  end

  private

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

  def llm_thinking_options
    return nil if llm_feature_key.blank?

    Llm::RuntimePolicy.thinking_options(
      feature: llm_feature_key,
      account: llm_model_account,
      model: model
    )
  end
end
