# frozen_string_literal: true

class Llm::ApiClient
  class << self
    def configure(&)
      RubyLLM.configure(&)
    end

    def context(&)
      RubyLLM.context(&)
    end

    def embed(*args, **kwargs, &block)
      observability = kwargs.delete(:observability)
      payload = Llm::ObservabilityPayload.normalize(
        observability,
        model: kwargs[:model],
        runtime_mode: 'api_client'
      )
      return RubyLLM.embed(*args, **kwargs, &block) if payload.blank?

      Llm::EventBus.publish('embedding.complete', payload) do |event_payload|
        begin
          response = RubyLLM.embed(*args, **kwargs, &block)
          Llm::ObservabilityPayload.attach_embedding_response!(event_payload, response)
          response
        rescue StandardError => e
          Llm::ObservabilityPayload.attach_error!(event_payload, e)
          raise
        end
      end
    end

    def moderate(*args, **kwargs, &block)
      observability = kwargs.delete(:observability)
      payload = Llm::ObservabilityPayload.normalize(
        observability,
        model: kwargs[:model],
        runtime_mode: 'api_client'
      )
      return RubyLLM.moderate(*args, **kwargs, &block) if payload.blank?

      Llm::EventBus.publish('moderation.complete', payload) do |event_payload|
        begin
          response = RubyLLM.moderate(*args, **kwargs, &block)
          Llm::ObservabilityPayload.attach_moderation_response!(event_payload, response)
          response
        rescue StandardError => e
          Llm::ObservabilityPayload.attach_error!(event_payload, e)
          raise
        end
      end
    end

    def transcribe(*args, **kwargs, &block)
      observability = kwargs.delete(:observability)
      payload = Llm::ObservabilityPayload.normalize(
        observability,
        model: kwargs[:model],
        runtime_mode: 'api_client'
      )
      return RubyLLM.transcribe(*args, **kwargs, &block) if payload.blank?

      Llm::EventBus.publish('transcription.complete', payload) do |event_payload|
        begin
          response = RubyLLM.transcribe(*args, **kwargs, &block)
          Llm::ObservabilityPayload.attach_transcription_response!(event_payload, response)
          response
        rescue StandardError => e
          Llm::ObservabilityPayload.attach_error!(event_payload, e)
          raise
        end
      end
    end
  end
end
