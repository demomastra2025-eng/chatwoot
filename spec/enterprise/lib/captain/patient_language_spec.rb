# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::PatientLanguage do
  it 'is the start of the language rule of the platform prompt, word for word' do
    liquid = File.read(Captain::PromptRegistry::ROOT.join('assistant.liquid'))

    expect(liquid).to include("- #{described_class::RULE} Briefly, naming specialists and services as the clinic data names them")
  end

  it 'names the language in words that need no code to detect it: the model decides, in any alphabet' do
    expect(described_class::RULE).to eq(
      "Reply in the patient's language: the language of most of the patient's words in the conversation, in any alphabet " \
      '(Kazakh may be written in Russian or Latin letters). Keep it when a message contains words of another language.'
    )
    expect(described_class::FIELD_DESCRIPTION)
      .to eq("The patient's language per the platform rule, e.g. Kazakh, Russian, English; decide it before writing the reply.")
  end

  describe 'the structured request to the model' do
    let(:account) { create(:account) }
    let(:model) { 'vendor/language-model' }
    let(:model_config) do
      {
        'provider' => 'openrouter', 'type' => 'chat', 'capabilities' => %w[structured_output tool_calling tool_choice],
        'supported_parameters' => %w[temperature tools tool_choice response_format structured_outputs]
      }
    end
    let(:llm_context) do
      RubyLLM.context do |config|
        config.openrouter_api_key = 'test-only-key'
        config.openrouter_api_base = 'https://openrouter.example/api/v1'
      end
    end

    before do
      allow(Llm::OpenRouterModelCatalog).to receive(:model_configs).and_return(model => model_config)
      allow(Llm::Config).to receive(:provider_available?) { |provider, **| provider == 'openrouter' }
      allow(Llm::Models).to receive(:model_config).and_call_original
      allow(Llm::Models).to receive(:model_config).with(model, account: account).and_return(model_config)
    end

    # The model writes the properties in the order of the JSON schema it is sent, so the order on the wire is what counts.
    [Captain::ResponseSchema, Captain::Runtime::PartSchema].each do |schema|
      it "sends #{schema.name} with patient_language as the first property" do
        sent = nil
        stub_request(:post, 'https://openrouter.example/api/v1/chat/completions')
          .with { |http_request| (sent = JSON.parse(http_request.body)) && true }
          .to_return(status: 200, headers: { 'Content-Type' => 'application/json' },
                     body: { id: 'g', model: model, choices: [{ index: 0, message: { role: 'assistant', content: '{}' }, finish_reason: 'stop' }],
                             usage: { prompt_tokens: 1, completion_tokens: 1 } }.to_json)
        chat = Llm::Runtime.build_chat(feature: :captain_agent, account: account, model: model, runtime_preferences: {},
                                       options: { context: llm_context, headers: {} })
        Llm::StructuredOutputPolicy.bind!(chat: chat, schema: schema)

        begin
          chat.ask('Test message')
        rescue StandardError
          # The reply is not the subject of this example: the request body is.
          nil
        end

        sent_schema = sent.dig('response_format', 'json_schema', 'schema')
        reply_key = schema == Captain::ResponseSchema ? 'response' : 'customer_text'
        expect(sent_schema['properties'].keys.first).to eq('patient_language')
        expect(sent_schema['properties'].keys.index('patient_language')).to be < sent_schema['properties'].keys.index(reply_key)
        expect(sent_schema['required']).to include('patient_language')
      end
    end
  end
end
