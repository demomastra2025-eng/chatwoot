# frozen_string_literal: true

class Llm::ObservabilityPayload
  class << self
    def normalize(payload = nil, model: nil, feature: nil, runtime_mode: nil)
      source = payload.to_h.with_indifferent_access
      metadata = source[:metadata].to_h.with_indifferent_access
      resolved_model = source[:model].presence || model

      {
        request_id: source[:request_id].presence || metadata[:request_id],
        feature: source[:feature].presence || source[:feature_name].presence || feature,
        runtime_mode: source[:runtime_mode].presence || runtime_mode,
        status: source[:status],
        reason: source[:reason],
        provider: source[:provider].presence || provider_for(resolved_model),
        model: resolved_model,
        trace_id: source[:trace_id].presence || metadata[:trace_id],
        trace_name: source[:trace_name].presence || metadata[:trace_name],
        root_span_id: source[:root_span_id].presence || metadata[:root_span_id],
        span_id: source[:span_id].presence || metadata[:span_id],
        parent_span_id: source[:parent_span_id].presence || metadata[:parent_span_id],
        span_kind: source[:span_kind].presence || metadata[:span_kind],
        span_name: source[:span_name].presence || metadata[:span_name],
        tool_name: source[:tool_name].presence || metadata[:tool_name],
        schema_name: source[:schema_name],
        current_agent: source[:current_agent].presence || metadata[:current_agent],
        channel_type: source[:channel_type].presence || metadata[:channel_type],
        source: source[:source].presence || metadata[:source],
        session_id: source[:session_id].presence || metadata[:session_id],
        account_id: source[:account_id],
        assistant_id: source[:assistant_id].presence || metadata[:assistant_id],
        conversation_id: source[:conversation_record_id].presence || source[:conversation_db_id],
        conversation_display_id: source[:conversation_display_id].presence || metadata[:conversation_display_id].presence || source[:conversation_id],
        copilot_thread_id: source[:copilot_thread_id].presence || metadata[:copilot_thread_id]
      }.compact
    rescue StandardError
      {}
    end

    def attach_chat_response!(payload, response)
      payload.merge!(chat_response_payload(response, provider: payload['provider'] || payload[:provider]))
      payload.compact!
      payload
    end

    def attach_embedding_response!(payload, response)
      vectors = response.respond_to?(:vectors) ? response.vectors : response
      vector_count, dimensions = vector_shape(vectors)

      payload['status'] = 'success'
      payload['error'] = false
      payload['prompt_tokens'] = token_value(response, :input_tokens)
      payload['total_tokens'] = payload['prompt_tokens']
      payload['vector_count'] = vector_count
      payload['dimensions'] = dimensions
      payload.compact!
      payload
    end

    def attach_transcription_response!(payload, response)
      text = response.respond_to?(:text) ? response.text.to_s : response.to_s

      payload['status'] = 'success'
      payload['error'] = false
      payload['prompt_tokens'] = token_value(response, :input_tokens)
      payload['completion_tokens'] = token_value(response, :output_tokens)
      payload['total_tokens'] = compact_sum(payload['prompt_tokens'], payload['completion_tokens'])
      payload['output_type'] = 'text'
      payload['output_size'] = text.bytesize
      payload.compact!
      payload
    end

    def attach_rerank_response!(payload, response)
      usage = response.respond_to?(:usage) && response.usage.respond_to?(:to_h) ? response.usage.to_h.with_indifferent_access : {}

      payload['status'] = 'success'
      payload['error'] = false
      payload['prompt_tokens'] = integer_value(usage[:prompt_tokens] || usage[:input_tokens])
      payload['completion_tokens'] = integer_value(usage[:completion_tokens] || usage[:output_tokens])
      payload['total_tokens'] = integer_value(usage[:total_tokens]) || compact_sum(payload['prompt_tokens'], payload['completion_tokens'])
      payload['estimated_cost'] = usage[:cost] || usage[:estimated_cost]
      payload['result_count'] = response.results.count if response.respond_to?(:results) && response.results.respond_to?(:count)
      payload.compact!
      payload
    end

    def attach_moderation_response!(payload, response)
      payload['status'] = response.respond_to?(:flagged?) && response.flagged? ? 'flagged' : 'allowed'
      payload['error'] = false
      payload['blocked'] = response.flagged? if response.respond_to?(:flagged?)
      payload['flagged_categories'] = response.flagged_categories if response.respond_to?(:flagged_categories)
      payload.compact!
      payload
    end

    def attach_error!(payload, error)
      payload['status'] = 'error'
      payload['error'] = true
      payload['reason'] = error.class.name.demodulize.underscore
      payload['error_class'] = error.class.name
      payload['error_message'] = error.message
      attach_openrouter_error_classification!(payload, error)
      payload.compact!
      payload
    end

    private

    def provider_for(model)
      return if model.blank?

      Llm::Config.provider_for_model(model)
    rescue StandardError
      nil
    end

    def attach_openrouter_error_classification!(payload, error)
      return unless openrouter_error_payload?(payload, error)

      classification = Llm::OpenRouterErrorClassifier.classify(error)
      return if classification.category == 'unknown'

      payload['openrouter_error_category'] = classification.category
      payload['retryable'] = classification.retryable
      payload['retry_after_seconds'] = classification.retry_after_seconds
    end

    def openrouter_error_payload?(payload, error)
      payload['provider'].to_s == 'openrouter' || payload[:provider].to_s == 'openrouter' || error.message.to_s.match?(/openrouter/i)
    end

    def token_value(response, method_name)
      response.public_send(method_name) if response.respond_to?(method_name)
    end

    def integer_value(value)
      return if value.blank?

      Integer(value)
    rescue ArgumentError, TypeError
      nil
    end

    def chat_response_payload(response, provider: nil)
      prompt_tokens = token_value(response, :input_tokens)
      completion_tokens = token_value(response, :output_tokens)
      {
        'status' => 'success',
        'error' => false,
        'prompt_tokens' => prompt_tokens,
        'completion_tokens' => completion_tokens,
        'thinking_tokens' => response_thinking_tokens(response),
        'total_tokens' => compact_sum(prompt_tokens, completion_tokens),
        'tool_call' => response_tool_call(response),
        'output_type' => response_output_type(response),
        'output_size' => response_output_size(response),
        'openrouter_generation_id' => openrouter_generation_id(response, provider: provider)
      }
    end

    def response_tool_call(response)
      response.tool_call? if response.respond_to?(:tool_call?)
    end

    def response_output_type(response)
      payload_type(response.content) if response.respond_to?(:content)
    end

    def response_output_size(response)
      payload_size(response.content) if response.respond_to?(:content)
    end

    def response_thinking_tokens(response)
      positive_token_value(token_value(response, :thinking_tokens) || token_value(response, :reasoning_tokens))
    end

    def openrouter_generation_id(response, provider:)
      return unless provider.to_s == 'openrouter'

      response_generation_id(response)
    end

    def response_generation_id(response)
      response_generation_id_from_methods(response) || response_generation_id_from_metadata(response)
    end

    def response_generation_id_from_methods(response)
      %i[openrouter_generation_id generation_id id].each do |method_name|
        next unless response.respond_to?(method_name)

        value = response.public_send(method_name)
        return value if value.present?
      end
      nil
    end

    def response_generation_id_from_metadata(response)
      %i[metadata raw to_h].each do |method_name|
        next unless response.respond_to?(method_name)

        value = nested_generation_id(response.public_send(method_name))
        return value if value.present?
      end
      nil
    rescue StandardError
      nil
    end

    def nested_generation_id(value)
      return unless value.respond_to?(:to_h)

      data = value.to_h.with_indifferent_access
      data[:openrouter_generation_id].presence ||
        data[:generation_id].presence ||
        data[:id].presence ||
        nested_generation_id(data[:data])
    end

    def compact_sum(*values)
      compact = values.compact
      return if compact.empty?

      compact.sum
    end

    def positive_token_value(value)
      tokens = value.to_i
      return if tokens <= 0

      tokens
    end

    def vector_shape(vectors)
      return [nil, nil] unless vectors.respond_to?(:count)

      normalized = Array(vectors)
      first_vector = normalized.first
      return [1, normalized.length] if first_vector.is_a?(Numeric)

      [
        normalized.count,
        first_vector.respond_to?(:length) ? first_vector.length : nil
      ]
    end

    def payload_type(value)
      case value
      when RubyLLM::Content
        value.attachments.present? ? 'multimodal_content' : 'text_content'
      when Hash
        'hash'
      when Array
        'array'
      when NilClass
        'nil'
      else
        value.class.name.demodulize.underscore
      end
    end

    def payload_size(value)
      case value
      when RubyLLM::Content
        Llm::MessageFormat.serialize_content(value).to_json.bytesize
      when Hash, Array
        value.to_json.bytesize
      else
        value.to_s.bytesize
      end
    end
  end
end
