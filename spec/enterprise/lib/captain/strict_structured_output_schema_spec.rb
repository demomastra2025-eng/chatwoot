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

  # A fixed set of values is an enum, so the provider offers the model these values and nothing else.
  {
    Captain::ResponseSchema => ['response_mode', %w[reply suppress]],
    Captain::Runtime::PartSchema => ['status', %w[answered needs_information out_of_scope unavailable]]
  }.each do |schema_class, (property, values)|
    it "offers #{schema_class.name} #{property} as an enum of #{values.join(', ')}, and sends it to OpenRouter unchanged" do
      properties = schema_class.new.to_json_schema.with_indifferent_access.dig(:schema, :properties)
      expect(properties.dig(property, :type)).to eq('string')
      expect(properties.dig(property, :enum)).to eq(values)

      # What Chat#with_schema keeps of the schema, and what the OpenRouter provider puts into response_format.
      schema = RubyLLM::Chat.allocate.send(:normalize_schema_payload, schema_class.new.to_json_schema)
      payload = RubyLLM::Providers::OpenRouter::Chat.render_payload(
        [], tools: {}, temperature: nil, model: Struct.new(:id).new('openai/gpt-6-luna'), schema: schema
      )
      sent = payload[:response_format][:json_schema]

      expect(payload[:response_format][:type]).to eq('json_schema')
      expect(sent[:strict]).to be(true)
      expect(sent[:schema].with_indifferent_access.dig(:properties, property, :enum)).to eq(values)
      expect(sent[:schema].with_indifferent_access[:required].map(&:to_s)).to match_array(properties.keys.map(&:to_s))
    end
  end

  describe 'a structured output with a value outside the enum' do
    def valid?(schema_class, output)
      JSONSchemer.schema(Llm::StructuredOutputSchema.definition_for(schema_class)).valid?(output)
    end

    it 'is refused for the part status, as the provider would not offer it' do
      complete = { 'patient_language' => 'Russian', 'customer_text' => 'Готово', 'status' => 'answered', 'questions' => [],
                   'sources' => [], 'suggested_agent' => '', 'reasoning' => 'done' }

      expect(valid?(Captain::Runtime::PartSchema, complete)).to be(true)
      expect(valid?(Captain::Runtime::PartSchema, complete.merge('status' => 'done'))).to be(false)
    end

    it 'is refused for the response mode' do
      complete = { 'patient_language' => 'Russian', 'response' => 'Готово', 'response_mode' => 'reply', 'reasoning' => 'done',
                   'artifact_ids' => [] }

      expect(valid?(Captain::ResponseSchema, complete)).to be(true)
      expect(valid?(Captain::ResponseSchema, complete.merge('response_mode' => 'suppress'))).to be(true)
      expect(valid?(Captain::ResponseSchema, complete.merge('response_mode' => 'handoff'))).to be(false)
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
