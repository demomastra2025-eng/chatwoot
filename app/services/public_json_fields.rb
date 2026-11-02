# frozen_string_literal: true

# Only declared properties, recursively. Scalar fields cannot smuggle objects or
# archives, and arrays retain only values of the declared element shape.
module PublicJsonFields
  SCALAR_TYPES = { string: [String], boolean: [TrueClass, FalseClass], number: [Numeric],
                   scalar: [NilClass, String, Numeric, TrueClass, FalseClass] }.freeze

  module_function

  def project(value, schema)
    return nil if value.nil?

    return project_object(value, schema) if schema.is_a?(Hash)
    return value.select { |item| valid_shape?(item, schema.first) }.map { |item| project(item, schema.first) } if schema.is_a?(Array)

    value
  end

  def project_object(value, schema)
    return {} unless value.is_a?(Hash)

    schema.each_with_object({}) do |(key, child), result|
      result[key] = project(value[key], child) if value.key?(key) && valid_shape?(value[key], child)
    end
  end

  def valid_shape?(value, schema)
    return true if value.nil?

    return value.is_a?(Hash) if schema.is_a?(Hash)
    return value.is_a?(Array) if schema.is_a?(Array)

    SCALAR_TYPES.fetch(schema).any? { |type| value.is_a?(type) }
  end

  def unknown_fields(value, schema, path)
    return [] unless value.respond_to?(:keys) && schema.is_a?(Hash)

    value.keys.flat_map do |key|
      field = "#{path}.#{key}"
      next [field] unless schema.key?(key.to_s)

      unknown_nested_fields(value[key], schema[key.to_s], field)
    end
  end

  def unknown_nested_fields(value, schema, path)
    return [] if value.nil?
    return object_unknown_fields(value, schema, path) if schema.is_a?(Hash)
    return value.is_a?(Array) ? array_unknown_fields(value, schema.first, path) : [path] if schema.is_a?(Array)

    value.respond_to?(:keys) || value.is_a?(Array) ? [path] : []
  end

  def object_unknown_fields(value, schema, path)
    value.respond_to?(:keys) ? unknown_fields(value, schema, path) : [path]
  end

  def array_unknown_fields(value, schema, path)
    value.each_with_index.flat_map { |item, index| unknown_nested_fields(item, schema, "#{path}.#{index}") }
  end

  def from_json_schema(schema)
    return schema.fetch('properties', {}).transform_values { |child| from_json_schema(child) } if Array(schema['type']).include?('object')
    return [from_json_schema(schema.fetch('items', {}))] if Array(schema['type']).include?('array')

    :scalar
  end
end
