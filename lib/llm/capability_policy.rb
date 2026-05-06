# frozen_string_literal: true

class Llm::CapabilityPolicy
  UnsupportedCapabilityError = Class.new(ArgumentError)

  class << self
    def ensure_thinking_supported!(model:, account: nil)
      ensure_supported!(model: model, capability: :reasoning, purpose: 'thinking', account: account)
    end

    def ensure_chat_features_supported!(model:, schema: nil, tools: [], account: nil)
      ensure_supported!(model: model, capability: :structured_output, purpose: 'structured outputs', account: account) if schema.present?
      ensure_supported!(model: model, capability: :tool_calling, purpose: 'tool calling', account: account) if tools.present?
    end

    def ensure_input_supported!(model:, content:, account: nil)
      return unless attachment_input?(content)

      required_attachment_capability_groups(content).each do |capabilities, purpose|
        ensure_any_supported!(model: model, capabilities: capabilities, purpose: purpose, account: account)
      end
    end

    def ensure_supported!(model:, capability:, purpose: nil, account: nil)
      return if model.blank?
      return if Llm::Models.supports?(model, capability, account: account)

      raise UnsupportedCapabilityError, "Model #{model} does not support #{purpose || capability.to_s.tr('_', ' ')}"
    end

    def ensure_any_supported!(model:, capabilities:, purpose:, account: nil)
      return if model.blank?
      return if capabilities.any? { |capability| Llm::Models.supports?(model, capability, account: account) }

      raise UnsupportedCapabilityError, "Model #{model} does not support #{purpose}"
    end

    private

    def attachment_input?(content)
      content.is_a?(RubyLLM::Content) && content.attachments.present?
    end

    def required_attachment_capability_groups(content)
      content.attachments.map do |attachment|
        attachment_capability_group(attachment)
      end.uniq
    end

    def attachment_capability_group(attachment)
      case attachment_type(attachment)
      when :audio
        [%i[audio_input multimodal_input], 'audio inputs']
      when :image
        [%i[image_input multimodal_input], 'image inputs']
      else
        [%i[multimodal_input], 'multimodal inputs']
      end
    end

    def attachment_type(attachment)
      attachment.type if attachment.respond_to?(:type)
    end
  end
end
