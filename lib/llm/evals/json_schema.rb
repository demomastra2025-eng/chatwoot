# frozen_string_literal: true

class Llm::Evals::JsonSchema
  attr_reader :name

  def initialize(name:, schema:)
    @name = name
    @schema = schema.to_h.deep_symbolize_keys
  end

  def to_json_schema
    @schema
  end
end
