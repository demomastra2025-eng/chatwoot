# frozen_string_literal: true

require 'json_schemer'

class Llm::StructuredOutputPolicy # rubocop:disable Metrics/ClassLength
  CHAT_SCHEMA_IVAR = :@onelink_structured_output_schema
  DEFAULT_MAX_ATTEMPTS = 3
  StructuredOutputError = Class.new(StandardError)
  InvalidStructuredOutputError = Class.new(StructuredOutputError)

  class << self
    def bind!(chat:, schema:)
      return chat if schema.blank?

      validate_schema!(schema)
      chat.instance_variable_set(CHAT_SCHEMA_IVAR, schema)
      enforce_openrouter_required_parameters!(chat)
      chat.with_schema(schema)
    end

    def execute(chat:, max_attempts: DEFAULT_MAX_ATTEMPTS)
      attempts = 0
      response = nil

      begin
        attempts += 1
        response = yield(attempts)
        normalize_response!(chat: chat, response: response)
      rescue InvalidStructuredOutputError => e
        raise if schema_for(chat).blank?

        if attempts >= max_attempts
          fallback_response = fallback_invalid_captain_response!(chat: chat, response: response)
          return fallback_response if fallback_response

          raise
        end

        prepare_retry!(chat: chat, response: response, error: e, attempt: attempts)
        retry
      end

      response
    end

    def normalize_response!(chat:, response:)
      schema = schema_for(chat)
      return response unless should_normalize_response?(schema, response)

      normalized_content = normalize_content(response.content, schema: schema)
      validate_content!(schema, normalized_content)
      validate_semantic_content!(schema, normalized_content)
      response.content = normalized_content if response.respond_to?(:content=)
      response
    rescue InvalidStructuredOutputError => e
      publish_invalid_event(chat: chat, response: response, error: e)
      raise InvalidStructuredOutputError, "#{e.message} for schema #{Llm::StructuredOutputSchema.name_for(schema)}"
    end

    def schema_for(chat)
      chat.instance_variable_get(CHAT_SCHEMA_IVAR)
    end

    private

    def prepare_retry!(chat:, response:, error:, attempt:)
      rollback_failed_response!(chat, response)
      publish_repair_requested_event(chat: chat, error: error, attempt: attempt)
      append_repair_instruction!(chat, error: error, attempt: attempt)
    end

    def validate_schema!(schema)
      Llm::StrictStructuredOutputSchemaValidator.validate!(schema)
    end

    def enforce_openrouter_required_parameters!(chat)
      Llm::OpenRouterRequestPolicy.require_structured_output!(chat)
    end

    def should_normalize_response?(schema, response)
      schema.present? && response.respond_to?(:content) && !halt_result?(response) &&
        !(response.respond_to?(:tool_call?) && response.tool_call?)
    end

    def normalize_content(content, schema:)
      normalized_content =
        if content.respond_to?(:with_indifferent_access)
          content.with_indifferent_access
        elsif hash_like?(content)
          content.to_h.with_indifferent_access
        elsif content.is_a?(Array)
          content
        else
          normalize_json_string(content)
        end

      Llm::CaptainResponseContentNormalizer.apply_defaults(schema, normalized_content)
    end

    def normalize_json_string(content)
      raise InvalidStructuredOutputError, 'Structured output response was blank' if content.blank?
      raise InvalidStructuredOutputError, 'Structured output response was not JSON' unless content.is_a?(String)

      parsed = parse_json_content(content)
      return parsed.with_indifferent_access if parsed.is_a?(Hash)
      return parsed if parsed.is_a?(Array)

      raise InvalidStructuredOutputError, 'Structured output response was not a JSON object or array'
    rescue JSON::ParserError
      raise InvalidStructuredOutputError, 'Structured output response was not valid JSON'
    end

    def parse_json_content(content)
      JSON.parse(content)
    rescue JSON::ParserError
      candidate = Llm::JsonDocumentExtractor.call(content)
      raise if candidate.blank?

      JSON.parse(candidate)
    end

    def hash_like?(content)
      content.respond_to?(:to_h) && !content.is_a?(String) && content.to_h.is_a?(Hash)
    rescue StandardError
      false
    end

    def validate_content!(schema, content)
      validation_errors = JSONSchemer.schema(Llm::StructuredOutputSchema.definition_for(schema)).validate(content).to_a
      return if validation_errors.empty?

      raise InvalidStructuredOutputError, "Structured output response did not match schema: #{format_validation_errors(validation_errors)}"
    end

    def validate_semantic_content!(schema, content)
      return unless Llm::CaptainResponseContentNormalizer.applicable?(schema)
      return unless content.respond_to?(:[])

      if Llm::CaptainResponseContentNormalizer.invalid_public_response?(content['response'])
        raise InvalidStructuredOutputError,
              Llm::CaptainResponseContentNormalizer.invalid_public_response_message(content['response'])
      end

      return if content['reasoning'].to_s.strip.present?

      raise InvalidStructuredOutputError, 'Captain response reasoning must be present'
    end

    def fallback_invalid_captain_response!(chat:, response:)
      schema = schema_for(chat)
      return unless response.respond_to?(:content)

      fallback = Llm::CaptainResponseContentNormalizer.plain_text_fallback(schema, response.content)
      return if fallback.blank?

      normalized_content = fallback.with_indifferent_access
      validate_content!(schema, normalized_content)
      response.content = normalized_content if response.respond_to?(:content=)
      response
    end

    def format_validation_errors(errors)
      errors.first(3).map do |error|
        pointer = error['data_pointer'].presence || '/'
        "#{pointer} #{error['type']}"
      end.join(', ')
    end

    def rollback_failed_response!(chat, response)
      return unless response
      return unless chat.respond_to?(:messages)
      return unless chat.messages.is_a?(Array)
      return unless chat.messages.last.equal?(response)

      chat.messages.pop
    end

    def append_repair_instruction!(chat, error:, attempt:)
      return unless chat.respond_to?(:with_instructions)

      chat.with_instructions(repair_prompt(error: error, attempt: attempt), append: true)
    end

    def repair_prompt(error:, attempt:)
      <<~PROMPT.squish
        The previous response did not satisfy the required structured output schema.
        Retry the answer and return only valid JSON that exactly matches the schema already provided.
        Use the completed tool results already present in the conversation when forming the response.
        If the schema includes a reasoning field, it must be non-empty and user-visible, not hidden chain-of-thought.
        Do not call another tool while repairing a schema error unless the answer is impossible without new data.
        Do not include markdown, prose, comments, or code fences.
        Attempt: #{attempt + 1}. Validation error: #{error.message}
      PROMPT
    end

    def publish_invalid_event(chat:, response:, error:)
      schema = schema_for(chat)
      Llm::EventBus.publish(
        'schema.invalid',
        schema_name: Llm::StructuredOutputSchema.name_for(schema),
        model: resolved_model_name(chat),
        reason: error.message,
        response_type: response.respond_to?(:content) ? response_type(response.content) : nil,
        response_size: response.respond_to?(:content) ? response_size(response.content) : nil,
        response_healing_enabled: response_healing_enabled?(chat),
        **Llm::MessageTokenPayload.for(response)
      )
    end

    def publish_repair_requested_event(chat:, error:, attempt:)
      schema = schema_for(chat)
      Llm::EventBus.publish(
        'schema.repair_requested',
        schema_name: Llm::StructuredOutputSchema.name_for(schema),
        model: resolved_model_name(chat),
        attempt: attempt + 1,
        reason: error.message,
        response_healing_enabled: response_healing_enabled?(chat)
      )
    end

    def resolved_model_name(chat)
      chat_model = chat&.model
      return chat_model.id if chat_model.respond_to?(:id)
      return chat_model if chat_model.present?

      nil
    end

    def response_healing_enabled?(chat)
      response_healing_plugin_ids(chat).include?(Llm::OpenRouterRequestPolicy::RESPONSE_HEALING_PLUGIN_ID)
    rescue StandardError
      false
    end

    def response_healing_plugin_ids(chat)
      Array(chat_params_value(chat, :plugins)).filter_map do |plugin|
        next unless plugin.respond_to?(:[])

        plugin[:id] || plugin['id']
      end.map(&:to_s)
    end

    def chat_params_value(chat, key)
      params = chat.respond_to?(:params) ? chat.params : {}
      return unless params.respond_to?(:[])

      params[key] || params[key.to_s]
    end

    def halt_result?(response)
      defined?(RubyLLM::Tool::Halt) && response.is_a?(RubyLLM::Tool::Halt)
    end

    def response_type(content)
      case content
      when Hash
        'hash'
      when Array
        'array'
      else
        content.class.name.demodulize.underscore
      end
    end

    def response_size(content)
      case content
      when Hash, Array
        content.to_json.bytesize
      else
        content.to_s.bytesize
      end
    end
  end
end
