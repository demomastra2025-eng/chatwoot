# frozen_string_literal: true

class Llm::ChatClient
  class << self
    def build(**options)
      account = options[:account]
      if options[:thinking].present?
        Llm::CapabilityPolicy.ensure_thinking_supported!(model: resolved_model_name(options[:chat], options[:model]), account: account)
      end

      llm_chat = options[:chat] || build_chat(context: options[:context], model: options[:model], account: account)
      tag_openrouter_routing_metadata(llm_chat, options, account: account)
      apply_chat_options(llm_chat, options, account: account).tap do |chat|
        tag_openrouter_routing_metadata(chat, options, account: account)
      end
    end

    def ask(chat, content, model: nil, observability: nil, account: nil)
      payload = observability_payload(observability, chat, model)
      return perform_ask(chat, content, model: model, account: account) if payload.blank?

      Llm::EventBus.publish('chat.complete', payload) do |event_payload|
        response = perform_ask(chat, content, model: model, account: account)
        Llm::ObservabilityPayload.attach_chat_response!(event_payload, response)
        response
      rescue StandardError => e
        Llm::ObservabilityPayload.attach_error!(event_payload, e)
        raise
      end
    end

    private

    def perform_ask(chat, content, model:, account: nil)
      Llm::StructuredOutputPolicy.execute(chat: chat) do
        if content.is_a?(RubyLLM::Content)
          attachments = content.attachments.filter_map { |attachment| attachment_source(attachment) }
          if attachments.any?
            Llm::CapabilityPolicy.ensure_input_supported!(model: resolved_model_name(chat, model), content: content, account: account)
          end
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

    def build_chat(context:, model:, account: nil)
      if assume_model_exists?(model, account: account)
        provider = account.present? ? Llm::Config.provider_for_model(model, account: account) : Llm::Config.provider_for_model(model)
        return context.chat(model: model, provider: provider, assume_model_exists: true) if context

        return RubyLLM.chat(model: model, provider: provider, assume_model_exists: true)
      end

      return context.chat(model: model) if context

      RubyLLM.chat(model: model)
    end

    def assume_model_exists?(model, account: nil)
      return false if model.blank?

      supported = account.present? ? Llm::Models.runtime_supported?(model, account: account) : Llm::Models.runtime_supported?(model)
      return false unless supported

      provider = account.present? ? Llm::Config.provider_for_model(model, account: account) : Llm::Config.provider_for_model(model)
      known = account.present? ? Llm::Models.registry_known?(model, account: account) : Llm::Models.registry_known?(model)
      provider == 'openrouter' || !known
    end

    def attachment_source(attachment)
      attachment.respond_to?(:source) ? attachment.source : attachment
    end

    def apply_chat_options(chat, options, account:)
      chat = chat.with_temperature(options[:temperature]) unless options[:temperature].nil?
      chat = chat.with_params(**options[:params]) if options[:params].present?
      chat = apply_reasoning_routing_policy(chat, options, account: account)
      headers = openrouter_headers(chat, options, account: account)
      chat = chat.with_headers(**headers) if headers.present?
      chat = chat.with_thinking(**options[:thinking]) if options[:thinking].present?
      chat
    end

    def openrouter_headers(chat, options, account:)
      provided = options[:headers].respond_to?(:to_h) ? options[:headers].to_h : {}
      return provided unless openrouter_headers_required?(chat, options, account: account)

      provided.merge(Llm::OpenRouterHeaders.attribution_headers)
    rescue StandardError
      provided || {}
    end

    def openrouter_headers_required?(chat, options, account:)
      model = options[:model].presence
      return Llm::Models.provider_for(model, account: account) == 'openrouter' if model.present?

      Llm::OpenRouterRequestPolicy.openrouter_chat?(chat, account: account, model: model)
    rescue StandardError
      false
    end

    def apply_reasoning_routing_policy(chat, options, account:)
      thinking = options[:thinking]
      return chat if thinking.blank?

      Llm::OpenRouterRequestPolicy.require_parameters!(
        chat,
        account: account,
        feature: options[:feature],
        model: options[:model],
        reasoning: true,
        tools: false,
        schema: false,
        stream: options[:stream]
      )
    end

    def tag_openrouter_routing_metadata(chat, options, account:)
      Llm::OpenRouterRequestPolicy.tag!(
        chat,
        feature: options[:feature],
        account: account,
        model: resolved_model_name(chat, options[:model]),
        stream: options[:stream],
        routing_metadata: options[:routing_metadata]
      )
    end

    def resolved_model_name(chat, fallback_model)
      return fallback_model if fallback_model.present?
      return unless chat.respond_to?(:model)

      chat_model = chat.model
      return chat_model.id if chat_model.respond_to?(:id)
      return chat_model if chat_model.present?
    end

    def observability_payload(observability, chat, fallback_model)
      routing_metadata = Llm::OpenRouterRequestPolicy.observability_metadata(chat)
      return {} if observability.blank? && routing_metadata.blank?

      source = routing_metadata.merge(observability_hash(observability))

      Llm::ObservabilityPayload.normalize(
        source,
        model: resolved_model_name(chat, fallback_model),
        runtime_mode: 'chat_client'
      )
    end

    def observability_hash(observability)
      return {} unless observability.respond_to?(:to_h)

      observability.to_h.symbolize_keys
    rescue StandardError
      {}
    end
  end
end
