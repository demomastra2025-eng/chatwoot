# frozen_string_literal: true

class Llm::ObservabilityPayload
  OPENROUTER_METADATA_KEYS = %i[
    requested_model actual_model endpoint_provider routing_profile runtime_profile
    models fallback_models openrouter_provider_order openrouter_provider_sort
    openrouter_allow_fallbacks openrouter_require_parameters openrouter_data_collection
    openrouter_zdr openrouter_plugins openrouter_server_tools openrouter_service_tier
    openrouter_native_endpoint openrouter_privacy_profile openrouter_guardrail_profile
    openrouter_cache_policy openrouter_plugin_policy openrouter_transform_policy
    openrouter_budget_policy openrouter_attribution openrouter_app_referer
    openrouter_app_title openrouter_response_cache openrouter_response_cache_ttl
    openrouter_response_cache_clear openrouter_response_cache_reason
    openrouter_parallel_tool_calls openrouter_omitted_params
  ].freeze

  MAX_GENERATION_ID_SEARCH_DEPTH = 8
  MAX_GENERATION_ID_SEARCH_NODES = 100
  OPENROUTER_GENERATION_ID_PATTERN = /\Agen[-_][A-Za-z0-9._:\-]+\z/
  OPENROUTER_GENERATION_ID_KEYS = %w[
    openrouter_generation_id generation_id x-generation-id X-Generation-Id id
  ].freeze

  class << self
    def normalize(payload = nil, model: nil, feature: nil, runtime_mode: nil)
      source = payload.to_h.with_indifferent_access
      metadata = source[:metadata].to_h.with_indifferent_access
      resolved_model = source[:model].presence || model

      base_payload = {
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
      }

      base_payload.merge(openrouter_metadata(source, metadata)).compact
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
      payload['error_message'] = sanitize_error_message(error)
      attach_openrouter_error_classification!(payload, error)
      payload.compact!
      payload
    end

    def sanitize_error_message(error)
      message = error.respond_to?(:message) ? error.message : error.to_s
      Llm::Monitoring::PayloadSanitizer.call(message.to_s)
    end

    private

    def provider_for(model)
      return if model.blank?

      Llm::Config.provider_for_model(model)
    rescue StandardError
      nil
    end

    def openrouter_metadata(source, metadata)
      OPENROUTER_METADATA_KEYS.each_with_object({}) do |key, result|
        value = source[key]
        value = metadata[key] if value.blank? && value != false && metadata.key?(key)
        result[key] = value if value.present? || value == false
      end
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

        value = normalize_generation_id(response.public_send(method_name))
        return value if value.present?
      end
      nil
    rescue StandardError, SystemStackError
      nil
    end

    def response_generation_id_from_metadata(response)
      %i[headers response_headers metadata raw to_h].each do |method_name|
        next unless response.respond_to?(method_name)

        value = nested_generation_id(response.public_send(method_name))
        return value if value.present?
      end
      nil
    rescue StandardError, SystemStackError
      nil
    end

    def nested_generation_id(value)
      queue = [[value, 0]]
      seen = {}
      visited_nodes = 0

      until queue.empty? || visited_nodes >= MAX_GENERATION_ID_SEARCH_NODES
        current, depth = queue.shift
        next if current.nil?

        object_id = generation_search_object_id(current)
        if object_id
          next if seen[object_id]

          seen[object_id] = true
        end

        container = generation_search_container(current)
        next unless container

        visited_nodes += 1

        case container
        when Hash
          generation_id = generation_id_from_hash(container)
          return generation_id if generation_id.present?

          next if depth >= MAX_GENERATION_ID_SEARCH_DEPTH

          container.each_value do |child|
            queue << [child, depth + 1] if generation_search_traversable?(child)
          end
        when Array
          next if depth >= MAX_GENERATION_ID_SEARCH_DEPTH

          container.each do |child|
            queue << [child, depth + 1] if generation_search_traversable?(child)
          end
        end
      end

      nil
    end

    def generation_search_object_id(value)
      return unless generation_search_traversable?(value)

      value.object_id
    end

    def generation_search_traversable?(value)
      value.is_a?(Hash) || value.is_a?(Array) || value.respond_to?(:to_h)
    end

    def generation_search_container(value)
      case value
      when Hash, Array
        return value
      else
        return unless value.respond_to?(:to_h)

        converted = value.to_h
        return converted if converted.is_a?(Hash) || converted.is_a?(Array)
      end

      nil
    rescue StandardError, SystemStackError
      nil
    end

    def generation_id_from_hash(data)
      OPENROUTER_GENERATION_ID_KEYS.each do |key|
        generation_id = normalize_generation_id(hash_value(data, key))
        return generation_id if generation_id.present?
      end

      nil
    end

    def hash_value(data, key)
      return unless data.respond_to?(:key?)

      string_key = key.to_s
      symbol_key = string_key.to_sym
      underscored_symbol_key = string_key.tr('-', '_').to_sym

      return data[key] if data.key?(key)
      return data[string_key] if data.key?(string_key)
      return data[symbol_key] if data.key?(symbol_key)
      return data[underscored_symbol_key] if data.key?(underscored_symbol_key)

      data.each_pair do |candidate_key, candidate_value|
        return candidate_value if candidate_key.to_s.casecmp(string_key).zero?
      end

      nil
    rescue StandardError
      nil
    end

    def normalize_generation_id(value)
      return if value.blank?

      generation_id = value.to_s.strip
      return if generation_id.blank?

      generation_id if generation_id.match?(OPENROUTER_GENERATION_ID_PATTERN)
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
