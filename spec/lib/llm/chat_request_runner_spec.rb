# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::ChatRequestRunner do
  let(:chat) { instance_double(RubyLLM::Chat) }
  let(:context) { instance_double(RubyLLM::Context, chat: chat) }
  let(:response) { instance_double(RubyLLM::Message, content: 'Done') }
  let(:chat_model) { instance_double(RubyLLM::Model::Info, id: 'gpt-4.1-mini') }

  before do
    allow(chat).to receive(:with_params).and_return(chat)
    allow(chat).to receive(:with_headers).and_return(chat)
    allow(chat).to receive(:with_temperature).and_return(chat)
    allow(chat).to receive(:with_instructions).and_return(chat)
    allow(chat).to receive(:with_schema).and_return(chat)
    allow(chat).to receive(:with_tool).and_return(chat)
    allow(chat).to receive(:on_end_message).and_return(chat)
    allow(chat).to receive(:on_tool_call).and_return(chat)
    allow(chat).to receive(:on_tool_result).and_return(chat)
    allow(chat).to receive(:add_message)
    allow(chat).to receive(:ask).and_return(response)
    allow(chat).to receive(:model).and_return(chat_model)
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
    structured_response = instance_double(
      RubyLLM::Message,
      content: { 'message' => 'Done' },
      tool_call?: false
    )

    expect(chat).to receive(:with_schema).with(schema)
    expect(chat).to receive(:with_tool).with(tool)
    expect(chat).to receive(:ask).with('Hello').and_return(structured_response)

    result = described_class.new(
      context: context,
      model: 'gpt-4.1-mini',
      messages: [{ role: 'user', content: 'Hello' }],
      schema: schema,
      tools: [tool],
      params: { response_format: { type: 'json_object' } }
    ).call

    expect(result).to eq(structured_response)
    expect(chat).to have_received(:with_params).with(response_format: { type: 'json_object' })
  end

  it 'applies runtime chat options before asking' do
    expect(chat).to receive(:with_temperature).with(0).and_return(chat)
    expect(chat).to receive(:with_headers).with('HTTP-Referer': 'https://one-link.kz').and_return(chat)
    expect(chat).to receive(:ask).with('Hello').and_return(response)

    described_class.new(
      context: context,
      model: 'gpt-4.1-mini',
      messages: [{ role: 'user', content: 'Hello' }],
      temperature: 0,
      headers: { 'HTTP-Referer': 'https://one-link.kz' }
    ).call
  end

  it 'requires OpenRouter providers to support tool parameters for tools-only requests' do
    openrouter_model = instance_double(RubyLLM::Model::Info, id: 'deepseek/deepseek-v4-pro', provider: 'openrouter')
    tool = instance_double(RubyLLM::Tool)

    allow(chat).to receive(:model).and_return(openrouter_model)
    allow(chat).to receive(:params).and_return(provider: { allow_fallbacks: true })
    allow(Llm::Models).to receive(:supports?).and_call_original
    allow(Llm::Models).to receive(:supports?)
      .with('deepseek/deepseek-v4-pro', :tool_calling, account: nil)
      .and_return(true)

    expect(chat).to receive(:with_params) do |**params|
      expect(params).to include(
        models: start_with('deepseek/deepseek-v4-pro'),
        provider: include(
          allow_fallbacks: true,
          data_collection: 'deny',
          require_parameters: true
        )
      )
      chat
    end
    expect(chat).to receive(:with_tool).with(tool)
    expect(chat).to receive(:ask).with('Hello').and_return(response)

    described_class.new(
      chat: chat,
      messages: [{ role: 'user', content: 'Hello' }],
      tools: [tool]
    ).call
  end

  it 'raises when structured output is requested for a model without schema support' do
    allow(chat).to receive(:model).and_return(instance_double(RubyLLM::Model::Info, id: 'whisper-1'))
    schema = Class.new(RubyLLM::Schema) do
      string :message
    end

    expect do
      described_class.new(
        context: context,
        model: 'whisper-1',
        messages: [{ role: 'user', content: 'Hello' }],
        schema: schema
      ).call
    end.to raise_error(Llm::CapabilityPolicy::UnsupportedCapabilityError, /structured outputs/)
  end

  it 'raises when structured output response is not valid json' do
    schema = Class.new(RubyLLM::Schema) do
      string :message
    end

    invalid_response_one = instance_double(RubyLLM::Message, content: 'not-json', tool_call?: false)
    invalid_response_two = instance_double(RubyLLM::Message, content: 'still-not-json', tool_call?: false)
    invalid_response_three = instance_double(RubyLLM::Message, content: 'final-not-json', tool_call?: false)

    expect(chat).to receive(:with_instructions).with(/return only valid JSON/i, append: true).twice.and_return(chat)
    expect(chat).to receive(:ask).with('Hello').thrice.and_return(invalid_response_one, invalid_response_two, invalid_response_three)

    expect do
      described_class.new(
        context: context,
        model: 'gpt-4.1-mini',
        messages: [{ role: 'user', content: 'Hello' }],
        schema: schema
      ).call
    end.to raise_error(Llm::StructuredOutputPolicy::InvalidStructuredOutputError, /not valid JSON/)
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

  it 'publishes one observed chat event around runner execution' do
    events = []
    subscriber = ActiveSupport::Notifications.subscribe('llm.chat.complete') do |*args|
      events << ActiveSupport::Notifications::Event.new(*args)
    end
    observed_response = double(
      'message',
      content: 'Done',
      input_tokens: 3,
      output_tokens: 4,
      tool_call?: false
    )

    expect(chat).to receive(:ask).with('Hello').and_return(observed_response)

    result = described_class.new(
      context: context,
      model: 'gpt-4.1-mini',
      messages: [{ role: 'user', content: 'Hello' }],
      observability: {
        feature: 'assistant',
        account_id: 1,
        conversation_record_id: 2,
        conversation_display_id: 22
      }
    ).call

    expect(result).to eq(observed_response)
    expect(events.size).to eq(1)
    expect(events.first.payload).to include(
      'feature' => 'assistant',
      'account_id' => 1,
      'conversation_id' => 2,
      'conversation_display_id' => 22,
      'status' => 'success',
      'total_tokens' => 7
    )
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  it 'retries blank OpenRouter responses once when no tools can duplicate side effects' do
    openrouter_model = instance_double(RubyLLM::Model::Info, id: 'openai/gpt-5.4-mini', provider: 'openrouter')
    blank_response = instance_double(RubyLLM::Message, content: '', tool_call?: false)
    final_response = instance_double(RubyLLM::Message, content: 'Done', input_tokens: 3, output_tokens: 4, tool_call?: false)
    retry_events = []
    subscriber = ActiveSupport::Notifications.subscribe('llm.run.retry') do |*args|
      retry_events << ActiveSupport::Notifications::Event.new(*args)
    end

    allow(chat).to receive(:model).and_return(openrouter_model)
    expect(chat).to receive(:ask).with('Hello').twice.and_return(blank_response, final_response)

    result = described_class.new(
      chat: chat,
      model: 'openai/gpt-5.4-mini',
      messages: [{ role: 'user', content: 'Hello' }],
      observability: { feature: 'assistant', account_id: 1 }
    ).call

    expect(result).to eq(final_response)
    expect(retry_events.size).to eq(1)
    expect(retry_events.first.payload).to include(
      'feature' => 'assistant',
      'provider' => 'openrouter',
      'reason' => 'blank_response',
      'openrouter_error_category' => 'no_content_generated',
      'attempt' => 1,
      'max_attempts' => 2
    )
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  it 'rolls back failed retry attempts before asking the same chat again' do
    openrouter_model = instance_double(RubyLLM::Model::Info, id: 'openai/gpt-5.4-mini', provider: 'openrouter')
    messages = [instance_double(RubyLLM::Message, role: :user, content: 'History')]
    blank_response = instance_double(RubyLLM::Message, content: '', tool_call?: false)
    final_response = instance_double(RubyLLM::Message, content: 'Done', tool_call?: false)
    ask_attempts = 0

    allow(chat).to receive(:model).and_return(openrouter_model)
    allow(chat).to receive(:messages).and_return(messages)
    allow(chat).to receive(:ask) do |content|
      ask_attempts += 1
      response_for_attempt = ask_attempts == 1 ? blank_response : final_response
      messages << instance_double(RubyLLM::Message, role: :user, content: content)
      messages << response_for_attempt
      response_for_attempt
    end

    result = described_class.new(
      chat: chat,
      model: 'openai/gpt-5.4-mini',
      messages: [{ role: 'user', content: 'Hello' }]
    ).call

    expect(result).to eq(final_response)
    expect(messages.map(&:content)).to eq(%w[History Hello Done])
  end

  it 'does not retry blank OpenRouter responses for mutating tool flows' do
    openrouter_model = instance_double(RubyLLM::Model::Info, id: 'openai/gpt-5.4-mini', provider: 'openrouter')
    blank_response = instance_double(RubyLLM::Message, content: '', tool_call?: false)
    mutating_tool = Class.new do
      def name = 'update_deal'
      def tool_definition = { id: 'update_deal', risk_level: 'high', idempotent: false }
    end.new

    allow(chat).to receive(:model).and_return(openrouter_model)
    allow(Llm::Models).to receive(:supports?).and_call_original
    allow(Llm::Models).to receive(:supports?)
      .with('openai/gpt-5.4-mini', :tool_calling, account: nil)
      .and_return(true)
    expect(chat).to receive(:ask).with('Hello').once.and_return(blank_response)

    result = described_class.new(
      chat: chat,
      model: 'openai/gpt-5.4-mini',
      messages: [{ role: 'user', content: 'Hello' }],
      tools: [mutating_tool]
    ).call

    expect(result).to eq(blank_response)
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
    expect(chat).to receive(:ask).with('Describe it', with: [instance_of(URI::HTTPS)]).and_return(response)

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
