# frozen_string_literal: true

class Llm::StrictStructuredOutputSchemaValidator
  COMBINERS = %w[anyOf oneOf allOf].freeze

  class << self
    def validate!(schema)
      new(schema).validate!
    end
  end

  def initialize(schema)
    @schema = schema
  end

  def validate!
    schema_instance.validate! if schema_instance.respond_to?(:validate!)
    return unless definition.is_a?(Hash) && definition['strict'] == true

    validate_required_properties!(definition, pointer: '$')
  end

  private

  attr_reader :schema

  def schema_instance
    @schema_instance ||= schema.is_a?(Class) ? schema.new : schema
  end

  def definition
    @definition ||= Llm::StructuredOutputSchema.definition_for(schema)
  end

  def validate_required_properties!(node, pointer:)
    return unless node.is_a?(Hash)

    validate_node_properties!(node, pointer: pointer)
    validate_required_properties!(node['items'], pointer: "#{pointer}[]")
    validate_combiner_properties!(node, pointer: pointer)
  end

  def validate_node_properties!(node, pointer:)
    properties = node['properties']
    return unless properties.is_a?(Hash)

    required = Array(node['required']).map(&:to_s)
    missing = properties.keys.map(&:to_s) - required
    raise_missing_required!(missing, pointer: pointer) if missing.any?

    properties.each do |property_name, property_schema|
      validate_required_properties!(property_schema, pointer: "#{pointer}.#{property_name}")
    end
  end

  def validate_combiner_properties!(node, pointer:)
    COMBINERS.each do |combiner|
      Array(node[combiner]).each_with_index do |child_schema, index|
        validate_required_properties!(child_schema, pointer: "#{pointer}.#{combiner}[#{index}]")
      end
    end
  end

  def raise_missing_required!(missing, pointer:)
    raise ArgumentError,
          "Strict structured output schema #{Llm::StructuredOutputSchema.name_for(schema)} must include every property in required " \
          "at #{pointer}. Missing: #{missing.join(', ')}"
  end
end
