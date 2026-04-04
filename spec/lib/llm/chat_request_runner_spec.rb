# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::ChatRequestRunner do
  let(:chat) { instance_double(RubyLLM::Chat) }
  let(:context) { instance_double(RubyLLM::Context, chat: chat) }
  let(:response) { instance_double(RubyLLM::Message, content: 'Done') }

  before do
    allow(chat).to receive(:with_params).and_return(chat)
    allow(chat).to receive(:with_instructions).and_return(chat)
    allow(chat).to receive(:with_schema).and_return(chat)
    allow(chat).to receive(:with_tool).and_return(chat)
    allow(chat).to receive(:on_end_message).and_return(chat)
    allow(chat).to receive(:on_tool_call).and_return(chat)
    allow(chat).to receive(:on_tool_result).and_return(chat)
    allow(chat).to receive(:add_message)
    allow(chat).to receive(:ask).and_return(response)
  end

  it 'applies system instructions, restores history, and asks with the latest message' do
    messages = [
      { role: 'system', content: 'You are helpful' },
      { role: 'user', content: 'First question' },
      { role: 'assistant', content: 'First answer' },
      { role: 'user', content: 'Second question' }
    ]

    expect(chat).to receive(:with_instructions).with('You are helpful')
    expect(chat).to receive(:add_message).with(have_attributes(role: :user, content: 'First question')).ordered
    expect(chat).to receive(:add_message).with(have_attributes(role: :assistant, content: 'First answer')).ordered
    expect(chat).to receive(:ask).with('Second question').and_return(response)

    result = described_class.new(context: context, model: 'gpt-4', messages: messages).call

    expect(result).to eq(response)
  end

  it 'restores assistant tool calls and tool results from history', :aggregate_failures do
    messages = [
      {
        role: 'assistant',
        content: '',
        tool_calls: [
          { id: 'call_1', name: 'lookup_contact', arguments: { contact_id: 123 } }
        ]
      },
      {
        role: 'tool',
        content: 'Contact found',
        tool_call_id: 'call_1'
      },
      { role: 'user', content: 'What happened?' }
    ]

    expect(chat).to receive(:add_message) do |message|
      expect(message).to be_a(RubyLLM::Message)
      expect(message.role).to eq(:assistant)
      expect(message.tool_calls['call_1']).to be_a(RubyLLM::ToolCall)
      expect(message.tool_calls['call_1'].name).to eq('lookup_contact')
    end.ordered

    expect(chat).to receive(:add_message) do |message|
      expect(message).to be_a(RubyLLM::Message)
      expect(message.role).to eq(:tool)
      expect(message.tool_call_id).to eq('call_1')
      expect(message.content).to eq('Contact found')
    end.ordered

    expect(chat).to receive(:ask).with('What happened?').and_return(response)

    described_class.new(context: context, model: 'gpt-4', messages: messages).call
  end

  it 'combines multiple system messages into one instruction payload' do
    messages = [
      { role: 'system', content: 'First system rule' },
      { role: 'system', content: 'Second system rule' },
      { role: 'user', content: 'Hello' }
    ]

    expect(chat).to receive(:with_instructions).with("First system rule\n\nSecond system rule")
    expect(chat).to receive(:ask).with('Hello').and_return(response)

    described_class.new(context: context, model: 'gpt-4', messages: messages).call
  end

  it 'configures schema and tools when provided' do
    schema = Class.new(RubyLLM::Schema) do
      string :message
    end
    tool = instance_double(RubyLLM::Tool)

    expect(chat).to receive(:with_schema).with(schema)
    expect(chat).to receive(:with_tool).with(tool)

    described_class.new(
      context: context,
      model: 'gpt-4',
      messages: [{ role: 'user', content: 'Hello' }],
      schema: schema,
      tools: [tool],
      params: { response_format: { type: 'json_object' } }
    ).call

    expect(chat).to have_received(:with_params).with(response_format: { type: 'json_object' })
  end

  it 'registers an end_message callback with access to the chat instance' do
    captured_callback = nil

    expect(chat).to receive(:on_end_message) do |&block|
      captured_callback = block
    end

    described_class.new(
      context: context,
      model: 'gpt-4',
      messages: [{ role: 'user', content: 'Hello' }],
      tools: [instance_double(RubyLLM::Tool)],
      on_end_message: ->(runner_chat, message) { [runner_chat, message] }
    ).call

    expect(captured_callback.call(response)).to eq([chat, response])
  end

  it 'registers tool callbacks when provided' do
    tool_call_callback = nil
    tool_result_callback = nil

    expect(chat).to receive(:on_tool_call) { |&block| tool_call_callback = block }
    expect(chat).to receive(:on_tool_result) { |&block| tool_result_callback = block }

    described_class.new(
      context: context,
      model: 'gpt-4',
      messages: [{ role: 'user', content: 'Hello' }],
      on_tool_call: ->(tool_call) { [:tool_call, tool_call] },
      on_tool_result: ->(result) { [:tool_result, result] }
    ).call

    expect(tool_call_callback.call('call')).to eq([:tool_call, 'call'])
    expect(tool_result_callback.call('result')).to eq([:tool_result, 'result'])
  end

  it 'supports an already configured chat instance and multimodal content building' do
    content_builder = lambda do |content|
      next content unless content.is_a?(Array)

      text = content.find { |part| part[:type] == 'text' }&.dig(:text)
      image = content.find { |part| part[:type] == 'image_url' }&.dig(:image_url, :url)
      RubyLLM::Content.new(text, [image])
    end

    expect(context).not_to receive(:chat)
    expect(chat).to receive(:add_message) do |message|
      expect(message).to be_a(RubyLLM::Message)
      expect(message.content).to be_a(RubyLLM::Content)
      expect(message.content.attachments.first.source.to_s).to eq('https://example.com/history.png')
    end
    expect(chat).to receive(:ask).with('Describe it', with: ['https://example.com/final.png']).and_return(response)

    described_class.new(
      chat: chat,
      messages: [
        {
          role: 'user',
          content: [
            { type: 'text', text: 'History image' },
            { type: 'image_url', image_url: { url: 'https://example.com/history.png' } }
          ]
        },
        {
          role: 'user',
          content: [
            { type: 'text', text: 'Describe it' },
            { type: 'image_url', image_url: { url: 'https://example.com/final.png' } }
          ]
        }
      ],
      content_builder: content_builder
    ).call
  end

  it 'returns nil when there are no non-system conversation messages' do
    result = described_class.new(
      context: context,
      model: 'gpt-4',
      messages: [{ role: 'system', content: 'Only system prompt' }]
    ).call

    expect(result).to be_nil
    expect(chat).not_to have_received(:ask)
  end
end
