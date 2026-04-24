# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Captain strict structured output schemas' do
  [
    Captain::ResponseSchema,
    Captain::ConversationCompletionSchema
  ].each do |schema_class|
    it "keeps #{schema_class.name} compatible with OpenAI strict structured outputs" do
      schema_payload = schema_class.new.to_json_schema.with_indifferent_access
      schema = schema_payload[:schema].with_indifferent_access
      property_keys = schema[:properties].keys.map(&:to_s)
      required_keys = Array(schema[:required]).map(&:to_s)

      expect(schema[:strict]).to be(true)
      expect(required_keys).to match_array(property_keys)
    end
  end
end
