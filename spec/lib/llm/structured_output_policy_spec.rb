# frozen_string_literal: true

require 'rails_helper'

class StructuredOutputPolicySpecChat
  attr_reader :messages, :instructions, :model, :params

  def initialize(responses, model: 'gpt-4.1-mini')
    @responses = responses
    @messages = []
    @instructions = []
    @model = model
    @params = {}
  end

  def with_schema(_schema)
    self
  end

  def with_params(**params)
    @params = params
    self
  end

  def with_instructions(value, append: false, replace: nil)
    @instructions << { value: value, append: append, replace: replace }
    self
  end

  def ask(_content)
    response = @responses.shift
    @messages << response
    response
  end
end

class StructuredOutputPolicySpecResponse
  attr_accessor :content

  def initialize(content)
    @content = content
  end

  def tool_call?
    false
  end
end

RSpec.describe Llm::StructuredOutputPolicy do
  let(:chat) { instance_double(RubyLLM::Chat) }
  let(:schema) do
    Class.new(RubyLLM::Schema) do
      string :message
    end
  end
  let(:events) { [] }
  let(:captain_content) do
    {
      'patient_language' => '',
      'response' => 'Done',
      'response_mode' => 'reply',
      'reasoning' => 'Checked the tool result before replying.',
      'artifact_ids' => []
    }
  end
  let(:subscriber) do
    ActiveSupport::Notifications.subscribe(/llm\.schema\./) do |*args|
      events << ActiveSupport::Notifications::Event.new(*args)
    end
  end

  before do
    allow(chat).to receive(:with_schema).and_return(chat)
    allow(chat).to receive(:model).and_return('gpt-4.1-mini')
    subscriber
  end

  after do
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  def captain_response_schema_required_keys
    Llm::StructuredOutputSchema.definition_for(Captain::ResponseSchema).fetch('required')
  end

  describe '.bind!' do
    it 'validates and binds schema metadata to the chat' do
      expect(chat).to receive(:with_schema).with(schema).and_return(chat)

      result = described_class.bind!(chat: chat, schema: schema)

      expect(result).to eq(chat)
      expect(described_class.schema_for(chat)).to eq(schema)
    end

    it 'requires OpenRouter providers to support structured output parameters' do
      openrouter_model = instance_double(RubyLLM::Model::Info, id: 'deepseek/deepseek-v4-pro', provider: 'openrouter')
      openrouter_chat = StructuredOutputPolicySpecChat.new([], model: openrouter_model)
      openrouter_chat.with_params(
        'logit_bias' => { '123' => -1 },
        'provider' => { allow_fallbacks: true },
        'max_tokens' => 200
      )

      described_class.bind!(chat: openrouter_chat, schema: schema)

      expect(openrouter_chat.params).to include(
        'logit_bias' => { '123' => -1 },
        'max_tokens' => 200,
        :provider => include(allow_fallbacks: true, require_parameters: true),
        :plugins => include({ id: 'response-healing' })
      )
    end

    it 'rejects strict schemas whose required list omits a declared property' do
      invalid_schema = Class.new(RubyLLM::Schema) do
        string :message
        string :handoff_message, required: false
      end

      expect(chat).not_to receive(:with_schema)

      expect do
        described_class.bind!(chat: chat, schema: invalid_schema)
      end.to raise_error(ArgumentError, /required.*handoff_message/)
    end
  end

  describe '.normalize_response!' do
    it 'returns unmodified response when no schema is bound' do
      response = instance_double(RubyLLM::Message, content: 'plain text')

      expect(described_class.normalize_response!(chat: chat, response: response)).to eq(response)
    end

    it 'keeps hash payloads for structured output responses' do
      described_class.bind!(chat: chat, schema: schema)
      response = instance_double(RubyLLM::Message, content: { 'message' => 'Done' }, tool_call?: false)

      expect(described_class.normalize_response!(chat: chat, response: response)).to eq(response)
    end

    it 'bypasses schema normalization for halting tool results' do
      described_class.bind!(chat: chat, schema: schema)
      response = RubyLLM::Tool::Halt.new('Transferred to specialist')

      expect(described_class.normalize_response!(chat: chat, response: response)).to eq(response)
    end

    it 'parses json strings into hash payloads' do
      described_class.bind!(chat: chat, schema: schema)
      response = instance_double(
        RubyLLM::Message,
        content: '{"message":"Done"}',
        tool_call?: false,
        'content=': nil
      )

      expect(response).to receive(:content=).with(hash_including('message' => 'Done'))

      described_class.normalize_response!(chat: chat, response: response)
    end

    it 'parses json wrapped in markdown fences' do
      described_class.bind!(chat: chat, schema: schema)
      response = instance_double(
        RubyLLM::Message,
        content: "```json\n{\"message\":\"Done\"}\n```",
        tool_call?: false,
        'content=': nil
      )

      expect(response).to receive(:content=).with(hash_including('message' => 'Done'))

      described_class.normalize_response!(chat: chat, response: response)
    end

    it 'parses json after provider reasoning tags' do
      described_class.bind!(chat: chat, schema: schema)
      response = instance_double(
        RubyLLM::Message,
        content: "<think>I should validate the tool result.</think>\n{\"message\":\"Done\"}",
        tool_call?: false,
        'content=': nil
      )

      expect(response).to receive(:content=).with(hash_including('message' => 'Done'))

      described_class.normalize_response!(chat: chat, response: response)
    end

    it 'asks the model for the language first, then the reply, its mode, a short reasoning and the files to attach, and nothing about a handoff' do
      schema_json = Captain::ResponseSchema.new.to_json_schema.with_indifferent_access[:schema].with_indifferent_access

      expect(schema_json[:properties].keys.map(&:to_s)).to eq(%w[patient_language response response_mode reasoning artifact_ids])
      expect(schema_json[:required].map(&:to_s)).to match_array(%w[patient_language response response_mode reasoning artifact_ids])
      expect(schema_json[:properties].dig(:response, :description)).to eq(Captain::ResponseSchema::RESPONSE_DESCRIPTION)
      expect(schema_json[:properties].dig(:response_mode, :description))
        .to eq("reply - send the reply; suppress - send nothing (the patient wrote only an 'ok', or staff already replied).")
      expect(schema_json[:properties].dig(:reasoning, :description))
        .to eq('One short phrase for the log: what the reply is based on. The patient never sees it.')
      expect(schema_json[:properties].dig(:artifact_ids, :description)).to eq('IDs of files from tool results to attach; otherwise an empty list.')
      expect(schema_json[:properties].values.pluck(:description).join(' ')).not_to include('conversation_handoff')
    end

    it 'adds Captain response defaults before schema validation' do
      described_class.bind!(chat: chat, schema: Captain::ResponseSchema)
      response = StructuredOutputPolicySpecResponse.new(
        '{"response":"Done","reasoning":"Checked the tool result before replying."}'
      )

      described_class.normalize_response!(chat: chat, response: response)

      expect(response.content).to eq(captain_content)
      expect(response.content.keys).to match_array(captain_response_schema_required_keys)
    end

    %i[hash json].each do |format|
      it "discards retired Captain handoff fields from #{format} content" do
        described_class.bind!(chat: chat, schema: Captain::ResponseSchema)
        expected_content = captain_content.merge('response' => 'conversation_handoff')
        legacy_content = expected_content.merge(
          'handoff_message' => 'A specialist will continue.',
          'handoff_reason' => 'The customer requested a specialist.',
          'handoff_status_reason' => 'Model-supplied status reason',
          'handoff_outcome_reason_id' => 'model_supplied_reason_id'
        )
        content = format == :json ? legacy_content.to_json : legacy_content.symbolize_keys
        response = StructuredOutputPolicySpecResponse.new(content)

        described_class.normalize_response!(chat: chat, response: response)

        expect(response.content).to eq(expected_content)
        expect(response.content.keys).to match_array(captain_response_schema_required_keys)
      end
    end

    it 'rejects unknown Captain fields even when retired handoff reason fields are present' do
      described_class.bind!(chat: chat, schema: Captain::ResponseSchema)
      response = StructuredOutputPolicySpecResponse.new(
        captain_content.merge(
          'handoff_status_reason' => 'Model-supplied status reason',
          'handoff_outcome_reason_id' => 'model_supplied_reason_id',
          'custom_guardrail' => { 'action' => 'handoff' }
        ).to_json
      )

      expect do
        described_class.normalize_response!(chat: chat, response: response)
      end.to raise_error(described_class::InvalidStructuredOutputError, /did not match schema/)
    end

    it 'rejects plain text Captain responses before the repair path runs' do
      described_class.bind!(chat: chat, schema: Captain::ResponseSchema)
      response = instance_double(
        RubyLLM::Message,
        content: "<think>internal scratchpad</think>\nГотово, обновил сделку.",
        tool_call?: false
      )

      expect do
        described_class.normalize_response!(chat: chat, response: response)
      end.to raise_error(described_class::InvalidStructuredOutputError, /not valid JSON/)
    end

    it 'rejects plain text Captain responses with unclosed provider reasoning tags' do
      retry_chat = StructuredOutputPolicySpecChat.new([
                                                        StructuredOutputPolicySpecResponse.new(
                                                          "<think>internal scratchpad\nГотово, обновил сделку."
                                                        )
                                                      ])
      described_class.bind!(chat: retry_chat, schema: Captain::ResponseSchema)

      expect do
        described_class.execute(chat: retry_chat, max_attempts: 1) { retry_chat.ask('Hello') }
      end.to raise_error(described_class::InvalidStructuredOutputError, /not valid JSON/)
    end

    it 'fills a safe visible reasoning default for Captain responses without reasoning' do
      described_class.bind!(chat: chat, schema: Captain::ResponseSchema)
      response = StructuredOutputPolicySpecResponse.new('{"response":"Done"}')

      described_class.normalize_response!(chat: chat, response: response)

      expect(response.content).to include(
        'patient_language' => '',
        'response' => 'Done',
        'reasoning' => 'Response generated from the current conversation and available tool results.',
        'artifact_ids' => []
      )
      expect(response.content.keys).to match_array(captain_response_schema_required_keys)
    end

    it 'delivers a Captain reply that comes without a language, and keeps the language a model names' do
      described_class.bind!(chat: chat, schema: Captain::ResponseSchema)
      named = StructuredOutputPolicySpecResponse.new('{"patient_language":"Kazakh","response":"Дайын.","reasoning":"Checked."}')
      unnamed = StructuredOutputPolicySpecResponse.new('{"response":"Готово.","reasoning":"Checked."}')

      described_class.normalize_response!(chat: chat, response: named)
      described_class.normalize_response!(chat: chat, response: unnamed)

      expect(named.content).to include('patient_language' => 'Kazakh', 'response' => 'Дайын.')
      expect(unnamed.content).to include('patient_language' => '', 'response' => 'Готово.')
    end

    it 'rejects boolean Captain responses instead of stringifying them' do
      described_class.bind!(chat: chat, schema: Captain::ResponseSchema)
      response = instance_double(
        RubyLLM::Message,
        content: '{"response":true,"reasoning":"Checked the request.","artifact_ids":[]}',
        tool_call?: false
      )

      expect do
        described_class.normalize_response!(chat: chat, response: response)
      end.to raise_error(described_class::InvalidStructuredOutputError, /did not match schema/)
    end

    it 'rejects schema placeholder Captain responses' do
      described_class.bind!(chat: chat, schema: Captain::ResponseSchema)
      response = instance_double(
        RubyLLM::Message,
        content: '{"response":"response","reasoning":"Need to use a CRM tool.","artifact_ids":[]}',
        tool_call?: false
      )

      expect do
        described_class.normalize_response!(chat: chat, response: response)
      end.to raise_error(described_class::InvalidStructuredOutputError, /invalid public response/)
    end

    it 'raises when structured output is not valid json' do
      described_class.bind!(chat: chat, schema: schema)
      response = instance_double(RubyLLM::Message, content: 'oops', tool_call?: false)

      expect do
        described_class.normalize_response!(chat: chat, response: response)
      end.to raise_error(described_class::InvalidStructuredOutputError, /not valid JSON/)
    end

    it 'raises when structured output does not match the schema' do
      described_class.bind!(chat: chat, schema: schema)
      response = instance_double(RubyLLM::Message, content: '{"unexpected":"field"}', tool_call?: false)

      expect do
        described_class.normalize_response!(chat: chat, response: response)
      end.to raise_error(described_class::InvalidStructuredOutputError, /did not match schema/)
    end
  end

  describe '.execute' do
    %w[openai/gpt-6-luna anthropic/claude-haiku-5.5].each do |model_id|
      it "accepts a complete five-field Captain response once without repair for #{model_id}" do
        model = instance_double(RubyLLM::Model::Info, id: model_id, provider: 'openrouter')
        complete = captain_content.merge('patient_language' => 'Kazakh')
        response = StructuredOutputPolicySpecResponse.new(complete.to_json)
        retry_chat = StructuredOutputPolicySpecChat.new([response], model: model)
        described_class.bind!(chat: retry_chat, schema: Captain::ResponseSchema)
        expect(retry_chat).to receive(:ask).with('Hello').once.and_call_original

        result = described_class.execute(chat: retry_chat) { retry_chat.ask('Hello') }

        expect(result.content).to eq(complete)
        expect(result.content.keys).to match_array(captain_response_schema_required_keys)
        expect(retry_chat.messages).to contain_exactly(response)
        expect(retry_chat.instructions).to be_empty
        expect(events).to be_empty
      end
    end

    it 'retries once with repair instructions and keeps only the successful response in history' do
      response_one = StructuredOutputPolicySpecResponse.new('{"unexpected":"field"}')
      response_two = StructuredOutputPolicySpecResponse.new('{"message":"Done"}')
      retry_chat = StructuredOutputPolicySpecChat.new([response_one, response_two])

      described_class.bind!(chat: retry_chat, schema: schema)

      result = described_class.execute(chat: retry_chat) { retry_chat.ask('Hello') }

      expect(result.content).to include('message' => 'Done')
      expect(retry_chat.instructions.last[:value]).to include('return only valid JSON that exactly matches the schema already provided')
      expect(retry_chat.messages).to contain_exactly(response_two)
      expect(events.map(&:name)).to include('llm.schema.invalid', 'llm.schema.repair_requested')
    end

    it 'records response-healing enablement in invalid-output repair telemetry' do
      openrouter_model = instance_double(RubyLLM::Model::Info, id: 'deepseek/deepseek-v4-pro', provider: 'openrouter')
      response_one = StructuredOutputPolicySpecResponse.new('{"unexpected":"field"}')
      response_two = StructuredOutputPolicySpecResponse.new('{"message":"Done"}')
      retry_chat = StructuredOutputPolicySpecChat.new([response_one, response_two], model: openrouter_model)

      described_class.bind!(chat: retry_chat, schema: schema)

      described_class.execute(chat: retry_chat) { retry_chat.ask('Hello') }

      invalid_event = events.find { |event| event.name == 'llm.schema.invalid' }
      repair_event = events.find { |event| event.name == 'llm.schema.repair_requested' }
      expect(invalid_event.payload).to include('response_healing_enabled' => true)
      expect(repair_event.payload).to include('response_healing_enabled' => true, 'attempt' => 2)
    end

    it 'retries Captain plain text responses and accepts repaired JSON with reasoning' do
      response_one = StructuredOutputPolicySpecResponse.new("<think>internal scratchpad</think>\nГотово, обновил сделку.")
      response_two = StructuredOutputPolicySpecResponse.new(
        {
          response: 'Готово, обновил сделку.',
          reasoning: 'Проверил результат инструмента и подтвердил обновление.',
          artifact_ids: []
        }.to_json
      )
      retry_chat = StructuredOutputPolicySpecChat.new([response_one, response_two])

      described_class.bind!(chat: retry_chat, schema: Captain::ResponseSchema)

      result = described_class.execute(chat: retry_chat) { retry_chat.ask('Hello') }

      expect(result.content).to include(
        'response' => 'Готово, обновил сделку.',
        'reasoning' => 'Проверил результат инструмента и подтвердил обновление.'
      )
      expect(retry_chat.messages).to contain_exactly(response_two)
    end

    it 'accepts Captain JSON responses that omit visible reasoning by applying a deterministic default' do
      response_one = StructuredOutputPolicySpecResponse.new('{"response":"Done"}')
      retry_chat = StructuredOutputPolicySpecChat.new([response_one])

      described_class.bind!(chat: retry_chat, schema: Captain::ResponseSchema)

      result = described_class.execute(chat: retry_chat) { retry_chat.ask('Hello') }

      expect(result.content).to include(
        'response' => 'Done',
        'reasoning' => 'Response generated from the current conversation and available tool results.'
      )
      expect(retry_chat.messages).to contain_exactly(response_one)
      expect(retry_chat.instructions).to be_empty
    end

    it 'retries Captain JSON responses with boolean public responses' do
      response_one = StructuredOutputPolicySpecResponse.new(
        '{"response":true,"reasoning":"Checked the request.","artifact_ids":[]}'
      )
      response_two = StructuredOutputPolicySpecResponse.new(
        {
          response: 'Готово, обновил сделку.',
          reasoning: 'Проверил результат инструмента и подтвердил обновление.',
          artifact_ids: []
        }.to_json
      )
      retry_chat = StructuredOutputPolicySpecChat.new([response_one, response_two])

      described_class.bind!(chat: retry_chat, schema: Captain::ResponseSchema)

      result = described_class.execute(chat: retry_chat) { retry_chat.ask('Hello') }

      expect(result.content).to include(
        'response' => 'Готово, обновил сделку.',
        'reasoning' => 'Проверил результат инструмента и подтвердил обновление.'
      )
      expect(retry_chat.messages).to contain_exactly(response_two)
    end

    it 'retries Captain JSON responses with schema placeholder public responses' do
      response_one = StructuredOutputPolicySpecResponse.new(
        '{"response":"response","reasoning":"Need to search CRM deals.","artifact_ids":[]}'
      )
      response_two = StructuredOutputPolicySpecResponse.new(
        '{"response":"Нашёл 1 сделку.","reasoning":"Использовал результат CRM-поиска перед ответом.","artifact_ids":[]}'
      )
      retry_chat = StructuredOutputPolicySpecChat.new([response_one, response_two])

      described_class.bind!(chat: retry_chat, schema: Captain::ResponseSchema)

      result = described_class.execute(chat: retry_chat) { retry_chat.ask('Hello') }

      expect(result.content).to include(
        'response' => 'Нашёл 1 сделку.',
        'reasoning' => 'Использовал результат CRM-поиска перед ответом.'
      )
      expect(retry_chat.messages).to contain_exactly(response_two)
    end

    it 'falls back to the final Captain plain text answer after repair attempts are exhausted' do
      response_one = StructuredOutputPolicySpecResponse.new('First plain text response')
      response_two = StructuredOutputPolicySpecResponse.new('Second plain text response')
      response_three = StructuredOutputPolicySpecResponse.new("<think>internal scratchpad</think>\nГотово, обновил сделку.")
      retry_chat = StructuredOutputPolicySpecChat.new([response_one, response_two, response_three])

      described_class.bind!(chat: retry_chat, schema: Captain::ResponseSchema)

      result = described_class.execute(chat: retry_chat) { retry_chat.ask('Hello') }

      expect(result.content).to eq(
        'patient_language' => '',
        'response' => 'Готово, обновил сделку.',
        'response_mode' => 'reply',
        'reasoning' => 'Response generated from the current conversation and available tool results.',
        'artifact_ids' => []
      )
      expect(result.content.keys).to match_array(captain_response_schema_required_keys)
      expect(retry_chat.messages).to contain_exactly(response_three)
    end

    it 'repairs a final Captain plain text answer before falling back' do
      response_one = StructuredOutputPolicySpecResponse.new("<think>internal scratchpad</think>\nГотово, обновил сделку.")
      response_two = StructuredOutputPolicySpecResponse.new('Готово, обновил сделку.')
      response_three = StructuredOutputPolicySpecResponse.new(
        {
          response: 'Готово, обновил сделку.',
          reasoning: 'Проверил результат инструмента и подтвердил обновление.',
          artifact_ids: []
        }.to_json
      )
      retry_chat = StructuredOutputPolicySpecChat.new([response_one, response_two, response_three])

      described_class.bind!(chat: retry_chat, schema: Captain::ResponseSchema)

      result = described_class.execute(chat: retry_chat) { retry_chat.ask('Hello') }

      expect(result.content).to include(
        'response' => 'Готово, обновил сделку.',
        'reasoning' => 'Проверил результат инструмента и подтвердил обновление.'
      )
      expect(retry_chat.instructions.size).to eq(2)
      expect(retry_chat.messages).to contain_exactly(response_three)
    end
  end
end
