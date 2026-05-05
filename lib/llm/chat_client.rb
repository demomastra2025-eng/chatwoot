# frozen_string_literal: true

class Llm::ChatClient
  class << self
    def build(**options)
      Llm::CapabilityPolicy.ensure_thinking_supported!(model: resolved_model_name(options[:chat], options[:model])) if options[:thinking].present?

      llm_chat = options[:chat] || build_chat(context: options[:context], model: options[:model])
      llm_chat = llm_chat.with_temperature(options[:temperature]) unless options[:temperature].nil?
      llm_chat = llm_chat.with_params(**options[:params]) if options[:params].present?
      llm_chat = llm_chat.with_headers(**options[:headers]) if options[:headers].present?
      llm_chat = llm_chat.with_thinking(**options[:thinking]) if options[:thinking].present?
      llm_chat
    end

    def ask(chat, content, model: nil, observability: nil)
      payload = observability_payload(observability, chat, model)
      return perform_ask(chat, content, model: model) if payload.blank?

      Llm::EventBus.publish('chat.complete', payload) do |event_payload|
        response = perform_ask(chat, content, model: model)
        Llm::ObservabilityPayload.attach_chat_response!(event_payload, response)
        response
      rescue StandardError => e
        Llm::ObservabilityPayload.attach_error!(event_payload, e)
        raise
      end
    end

    private

    def perform_ask(chat, content, model:)
      Llm::StructuredOutputPolicy.execute(chat: chat) do
        if content.is_a?(RubyLLM::Content)
          attachments = content.attachments.filter_map { |attachment| attachment_source(attachment) }
          Llm::CapabilityPolicy.ensure_input_supported!(model: resolved_model_name(chat, model), content: content) if attachments.any?
          if attachments.any?
            chat.ask(content.text, with: attachments)
          else
            chat.ask(content.text)
          end
        else
          chat.ask(content)
        end
      end
    end

    def build_chat(context:, model:)
      if assume_model_exists?(model)
        provider = Llm::Config.provider_for_model(model)
        return context.chat(model: model, provider: provider, assume_model_exists: true) if context

        return RubyLLM.chat(model: model, provider: provider, assume_model_exists: true)
      end

      return context.chat(model: model) if context

      RubyLLM.chat(model: model)
    end

    def assume_model_exists?(model)
      return false if model.blank?
      return false unless Llm::Models.runtime_supported?(model)

      Llm::Config.provider_for_model(model) == 'openrouter' || !Llm::Models.registry_known?(model)
    end

    def attachment_source(attachment)
      attachment.respond_to?(:source) ? attachment.source : attachment
    end

    def resolved_model_name(chat, fallback_model)
      chat_model = chat&.model
      return chat_model.id if chat_model.respond_to?(:id)
      return chat_model if chat_model.present?

      fallback_model
    end

    def observability_payload(observability, chat, fallback_model)
      return {} if observability.blank?

      Llm::ObservabilityPayload.normalize(
        observability,
        model: resolved_model_name(chat, fallback_model),
        runtime_mode: 'chat_client'
      )
    end
  end
end
