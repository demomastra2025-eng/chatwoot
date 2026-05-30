# frozen_string_literal: true

require 'json'

class Llm::StructuredOutputSchema
  class << self
    def definition_for(schema)
      schema_payload = schema_payload_for(schema)
      schema_payload = schema_payload.with_indifferent_access if schema_payload.respond_to?(:with_indifferent_access)
      definition = schema_payload[:schema] || schema_payload['schema'] || schema_payload
      JSON.parse(definition.to_json)
    end

    def name_for(schema)
      return schema.name if schema.respond_to?(:name) && schema.name.present?

      schema.class.name
    end

    private

    def schema_payload_for(schema)
      return schema.new.to_json_schema if schema.is_a?(Class)
      return schema.to_json_schema if schema.respond_to?(:to_json_schema)

      schema
    end
  end
end
