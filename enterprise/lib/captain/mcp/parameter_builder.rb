class Captain::Mcp::ParameterBuilder
  class << self
    def from_schema(schema)
      schema = schema.to_h.deep_stringify_keys if schema.respond_to?(:to_h)
      return {} unless schema.is_a?(Hash)
      return {} unless schema['type'].to_s == 'object'

      properties = schema.fetch('properties', {})
      required = Array(schema['required']).map(&:to_s)

      properties.each_with_object({}) do |(name, property_schema), memo|
        property_schema = property_schema.to_h.deep_stringify_keys if property_schema.respond_to?(:to_h)
        memo[name.to_sym] = RubyLLM::Parameter.new(
          name.to_sym,
          type: normalize_type(property_schema['type']),
          desc: property_schema['description'].to_s,
          required: required.include?(name.to_s)
        )
      end
    end

    private

    def normalize_type(type_name)
      case type_name.to_s
      when 'integer', 'number'
        'number'
      when 'boolean'
        'boolean'
      when 'array'
        'array'
      when 'object'
        'object'
      else
        'string'
      end
    end
  end
end
