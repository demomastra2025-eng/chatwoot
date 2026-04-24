# frozen_string_literal: true

require 'json_schemer'

class Llm::StructuredOutputPolicy
  CHAT_SCHEMA_IVAR = :@onelink_structured_output_schema
  DEFAULT_MAX_ATTEMPTS = 2

  StructuredOutputError = Class.new(StandardError)
  InvalidStructuredOutputError = Class.new(StructuredOutputError)

  class << self
    def bind!(chat:, schema:)
      return chat if schema.blank?

      validate_schema!(schema)
      chat.instance_variable_set(CHAT_SCHEMA_IVAR, schema)
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
        raise if schema_for(chat).blank? || attempts >= max_attempts

        prepare_retry!(chat: chat, response: response, error: e, attempt: attempts)
        retry
      end
    end

    def normalize_response!(chat:, response:)
      schema = schema_for(chat)
      return response if schema.blank?
      return response unless response.respond_to?(:content)
      return response if halt_result?(response)
      return response if response.respond_to?(:tool_call?) && response.tool_call?

      normalized_content = normalize_content(response.content)
      validate_content!(schema, normalized_content)
      response.content = normalized_content if response.respond_to?(:content=)
      response
    rescue InvalidStructuredOutputError => e
      publish_invalid_event(chat: chat, response: response, error: e)
      raise InvalidStructuredOutputError, "#{e.message} for schema #{schema_name(schema)}"
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
      schema_instance = schema.is_a?(Class) ? schema.new : schema
      schema_instance.validate! if schema_instance.respond_to?(:validate!)
      validate_openai_strict_required_properties!(schema)
    end

    def validate_openai_strict_required_properties!(schema)
      definition = schema_definition_for(schema)
      return unless definition.is_a?(Hash) && definition['strict'] == true

      validate_required_properties!(definition, schema_name: schema_name(schema), pointer: '$')
    end

    def validate_required_properties!(definition, schema_name:, pointer:)
      return unless definition.is_a?(Hash)

      properties = definition['properties']
      if properties.is_a?(Hash)
        required = Array(definition['required']).map(&:to_s)
        missing = properties.keys.map(&:to_s) - required
        if missing.any?
          raise ArgumentError,
                "Strict structured output schema #{schema_name} must include every property in required at #{pointer}. Missing: #{missing.join(', ')}"
        end

        properties.each do |property_name, property_schema|
          validate_required_properties!(property_schema, schema_name: schema_name, pointer: "#{pointer}.#{property_name}")
        end
      end

      validate_required_properties!(definition['items'], schema_name: schema_name, pointer: "#{pointer}[]") if definition['items'].is_a?(Hash)

      %w[anyOf oneOf allOf].each do |combiner|
        Array(definition[combiner]).each_with_index do |child_schema, index|
          validate_required_properties!(child_schema, schema_name: schema_name, pointer: "#{pointer}.#{combiner}[#{index}]")
        end
      end
    end

    def normalize_content(content)
      return content.with_indifferent_access if content.respond_to?(:with_indifferent_access)
      return content.to_h.with_indifferent_access if hash_like?(content)
      return content if content.is_a?(Array)

      normalize_json_string(content)
    end

    def normalize_json_string(content)
      raise InvalidStructuredOutputError, 'Structured output response was blank' if content.blank?
      raise InvalidStructuredOutputError, 'Structured output response was not JSON' unless content.is_a?(String)

      parsed = JSON.parse(content)
      return parsed.with_indifferent_access if parsed.is_a?(Hash)
      return parsed if parsed.is_a?(Array)

      raise InvalidStructuredOutputError, 'Structured output response was not a JSON object or array'
    rescue JSON::ParserError
      raise InvalidStructuredOutputError, 'Structured output response was not valid JSON'
    end

    def hash_like?(content)
      content.respond_to?(:to_h) && !content.is_a?(String) && content.to_h.is_a?(Hash)
    rescue StandardError
      false
    end

    def validate_content!(schema, content)
      validation_errors = JSONSchemer.schema(schema_definition_for(schema)).validate(content).to_a
      return if validation_errors.empty?

      raise InvalidStructuredOutputError, "Structured output response did not match schema: #{format_validation_errors(validation_errors)}"
    end

    def schema_definition_for(schema)
      schema_payload =
        if schema.is_a?(Class)
          schema.new.to_json_schema
        elsif schema.respond_to?(:to_json_schema)
          schema.to_json_schema
        else
          schema
        end
      schema_payload = schema_payload.with_indifferent_access if schema_payload.respond_to?(:with_indifferent_access)
      definition = schema_payload[:schema] || schema_payload['schema'] || schema_payload
      JSON.parse(definition.to_json)
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
        Do not include markdown, prose, comments, or code fences.
        Attempt: #{attempt + 1}. Validation error: #{error.message}
      PROMPT
    end

    def schema_name(schema)
      return schema.name if schema.respond_to?(:name) && schema.name.present?

      schema.class.name
    end

    def publish_invalid_event(chat:, response:, error:)
      schema = schema_for(chat)
      Llm::EventBus.publish(
        'schema.invalid',
        schema_name: schema_name(schema),
        model: resolved_model_name(chat),
        reason: error.message,
        response_type: response.respond_to?(:content) ? response_type(response.content) : nil,
        response_size: response.respond_to?(:content) ? response_size(response.content) : nil
      )
    end

    def publish_repair_requested_event(chat:, error:, attempt:)
      schema = schema_for(chat)
      Llm::EventBus.publish(
        'schema.repair_requested',
        schema_name: schema_name(schema),
        model: resolved_model_name(chat),
        attempt: attempt + 1,
        reason: error.message
      )
    end

    def resolved_model_name(chat)
      chat_model = chat&.model
      return chat_model.id if chat_model.respond_to?(:id)
      return chat_model if chat_model.present?

      nil
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
