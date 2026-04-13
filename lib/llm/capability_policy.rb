# frozen_string_literal: true

class Llm::CapabilityPolicy
  UnsupportedCapabilityError = Class.new(ArgumentError)

  class << self
    def ensure_thinking_supported!(model:)
      ensure_supported!(model:, capability: :reasoning, purpose: 'thinking')
    end

    def ensure_chat_features_supported!(model:, schema: nil, tools: [])
      ensure_supported!(model:, capability: :structured_output, purpose: 'structured outputs') if schema.present?
      ensure_supported!(model:, capability: :tool_calling, purpose: 'tool calling') if tools.present?
    end

    def ensure_input_supported!(model:, content:)
      return unless multimodal_input?(content)

      ensure_supported!(model:, capability: :multimodal_input, purpose: 'multimodal inputs')
    end

    def ensure_supported!(model:, capability:, purpose: nil)
      return if model.blank?
      return if Llm::Models.supports?(model, capability)

      raise UnsupportedCapabilityError, "Model #{model} does not support #{purpose || capability.to_s.tr('_', ' ')}"
    end

    private

    def multimodal_input?(content)
      content.is_a?(RubyLLM::Content) && content.attachments.present?
    end
  end
end
