# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Captain strict structured output schemas' do
  [
    Captain::ResponseSchema,
    Captain::Runtime::PartSchema,
    Captain::ConversationCompletionSchema,
    Captain::Llm::Schemas::CopilotResponse
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

  # The model writes the properties in the order of the schema, so the language is named before the words are written.
  {
    Captain::ResponseSchema => %w[patient_language response],
    Captain::Runtime::PartSchema => %w[patient_language customer_text]
  }.each do |schema_class, (language, text)|
    it "asks #{schema_class.name} for #{language} before #{text}, with the shared description" do
      properties = schema_class.new.to_json_schema.with_indifferent_access.dig(:schema, :properties)
      keys = properties.keys.map(&:to_s)

      expect(keys.first).to eq(language)
      expect(keys.index(language)).to be < keys.index(text)
      expect(properties.dig(language, :type)).to eq('string')
      expect(properties.dig(language, :description)).to eq(Captain::PatientLanguage::FIELD_DESCRIPTION)
    end
  end
end
