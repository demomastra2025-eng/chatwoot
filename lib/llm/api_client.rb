# frozen_string_literal: true

class Llm::ApiClient
  class << self
    def configure(&)
      RubyLLM.configure(&)
    end

    def context(&)
      RubyLLM.context(&)
    end

    def embed(*, **kwargs, &)
      context = kwargs.delete(:context)
      observability = kwargs.delete(:observability)
      payload = Llm::ObservabilityPayload.normalize(
        observability,
        model: kwargs[:model],
        runtime_mode: 'api_client'
      )
      return perform_contextual_call(context, :embed, *, **kwargs, &) if payload.blank?

      Llm::EventBus.publish('embedding.complete', payload) do |event_payload|
        response = perform_contextual_call(context, :embed, *, **kwargs, &)
        Llm::ObservabilityPayload.attach_embedding_response!(event_payload, response)
        response
      rescue StandardError => e
        Llm::ObservabilityPayload.attach_error!(event_payload, e)
        raise
      end
    end

    def moderate(*, **kwargs, &)
      context = kwargs.delete(:context)
      observability = kwargs.delete(:observability)
      payload = Llm::ObservabilityPayload.normalize(
        observability,
        model: kwargs[:model],
        runtime_mode: 'api_client'
      )
      return perform_contextual_call(context, :moderate, *, **kwargs, &) if payload.blank?

      Llm::EventBus.publish('moderation.complete', payload) do |event_payload|
        response = perform_contextual_call(context, :moderate, *, **kwargs, &)
        Llm::ObservabilityPayload.attach_moderation_response!(event_payload, response)
        response
      rescue StandardError => e
        Llm::ObservabilityPayload.attach_error!(event_payload, e)
        raise
      end
    end

    def transcribe(audio_file, **kwargs, &)
      context = kwargs.delete(:context)
      observability = kwargs.delete(:observability)
      payload = Llm::ObservabilityPayload.normalize(
        observability,
        model: kwargs[:model],
        runtime_mode: 'api_client'
      )
      return perform_transcription_call(audio_file, context: context, **kwargs, &) if payload.blank?

      Llm::EventBus.publish('transcription.complete', payload) do |event_payload|
        response = perform_transcription_call(audio_file, context: context, **kwargs, &)
        Llm::ObservabilityPayload.attach_transcription_response!(event_payload, response)
        response
      rescue StandardError => e
        Llm::ObservabilityPayload.attach_error!(event_payload, e)
        raise
      end
    end

    private

    def perform_contextual_call(context, method_name, ...)
      return context.public_send(method_name, ...) if context.respond_to?(method_name)

      RubyLLM.public_send(method_name, ...)
    end

    def perform_transcription_call(audio_file, context:, **kwargs, &)
      if kwargs[:provider].to_s == 'openrouter'
        return Llm::OpenRouterTranscriptionClient.transcribe(
          audio_file,
          model: kwargs[:model],
          api_key: kwargs[:api_key],
          api_base: kwargs[:api_base],
          language: kwargs[:language],
          temperature: kwargs[:temperature],
          provider: kwargs[:provider_preferences]
        )
      end

      perform_contextual_call(context, :transcribe, audio_file, **kwargs, &)
    end
  end
end
