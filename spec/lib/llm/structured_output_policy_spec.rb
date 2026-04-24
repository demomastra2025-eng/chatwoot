# frozen_string_literal: true

require 'rails_helper'

class StructuredOutputPolicySpecChat
  attr_reader :messages, :instructions, :model

  def initialize(responses, model: 'gpt-4.1-mini')
    @responses = responses
    @messages = []
    @instructions = []
    @model = model
  end

  def with_schema(_schema)
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

  describe '.bind!' do
    it 'validates and binds schema metadata to the chat' do
      expect(chat).to receive(:with_schema).with(schema).and_return(chat)

      result = described_class.bind!(chat: chat, schema: schema)

      expect(result).to eq(chat)
      expect(described_class.schema_for(chat)).to eq(schema)
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
  end
end
