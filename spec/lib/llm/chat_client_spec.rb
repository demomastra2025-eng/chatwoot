# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::ChatClient do
  let(:chat) { instance_double(RubyLLM::Chat) }
  let(:context) { instance_double(RubyLLM::Context, chat: chat) }
  let(:chat_model) { instance_double('RubyLLM::Model::Info', id: 'gpt-4.1-mini') }

  describe '.build' do
    before do
      allow(chat).to receive(:with_temperature).and_return(chat)
      allow(chat).to receive(:with_params).and_return(chat)
      allow(chat).to receive(:with_headers).and_return(chat)
      allow(chat).to receive(:with_thinking).and_return(chat)
      allow(RubyLLM).to receive(:chat).and_return(chat)
    end

    it 'builds a global chat and applies temperature' do
      expect(RubyLLM).to receive(:chat).with(model: 'gpt-4').and_return(chat)
      expect(chat).to receive(:with_temperature).with(0.3).and_return(chat)

      result = described_class.build(model: 'gpt-4', temperature: 0.3)

      expect(result).to eq(chat)
    end

    it 'builds a context chat and applies params' do
      expect(context).to receive(:chat).with(model: 'gpt-4').and_return(chat)
      expect(chat).to receive(:with_params).with(response_format: { type: 'json_object' }).and_return(chat)

      result = described_class.build(
        context: context,
        model: 'gpt-4',
        params: { response_format: { type: 'json_object' } }
      )

      expect(result).to eq(chat)
    end

    it 'applies custom headers when provided' do
      expect(RubyLLM).to receive(:chat).with(model: 'gpt-4').and_return(chat)
      expect(chat).to receive(:with_headers).with('X-Test' => 'value').and_return(chat)

      result = described_class.build(
        model: 'gpt-4',
        headers: { 'X-Test' => 'value' }
      )

      expect(result).to eq(chat)
    end

    it 'applies thinking options when provided' do
      expect(RubyLLM).to receive(:chat).with(model: 'gpt-5.1').and_return(chat)
      expect(chat).to receive(:with_thinking).with(effort: 'high').and_return(chat)

      result = described_class.build(
        model: 'gpt-5.1',
        thinking: { effort: 'high' }
      )

      expect(result).to eq(chat)
    end

    it 'builds Anthropic chats with explicit provider fallback when the registry lacks the model id' do
      allow(Llm::Models).to receive(:registry_known?).with('claude-sonnet-4-6').and_return(false)

      expect(RubyLLM).to receive(:chat).with(
        model: 'claude-sonnet-4-6',
        provider: 'anthropic',
        assume_model_exists: true
      ).and_return(chat)

      result = described_class.build(model: 'claude-sonnet-4-6')

      expect(result).to eq(chat)
    end

    it 'builds OpenRouter chats with explicit provider even for dynamically discovered models' do
      allow(Llm::Models).to receive(:runtime_supported?).with('openai/gpt-4o').and_return(true)
      allow(Llm::Config).to receive(:provider_for_model).with('openai/gpt-4o').and_return('openrouter')

      expect(RubyLLM).to receive(:chat).with(
        model: 'openai/gpt-4o',
        provider: 'openrouter',
        assume_model_exists: true
      ).and_return(chat)

      result = described_class.build(model: 'openai/gpt-4o')

      expect(result).to eq(chat)
    end

    it 'reuses an existing chat instance when provided' do
      expect(RubyLLM).not_to receive(:chat)
      expect(context).not_to receive(:chat)

      result = described_class.build(chat: chat, model: 'ignored')

      expect(result).to eq(chat)
    end

    it 'raises when thinking is requested for a model without reasoning support' do
      expect do
        described_class.build(
          model: 'gpt-4.1-mini',
          thinking: { effort: 'high' }
        )
      end.to raise_error(Llm::CapabilityPolicy::UnsupportedCapabilityError, /thinking/)
    end
  end

  describe '.ask' do
    it 'asks with plain content directly' do
      expect(chat).to receive(:ask).with('Hello')

      described_class.ask(chat, 'Hello')
    end

    it 'asks with multimodal content attachments when present' do
      allow(chat).to receive(:model).and_return(chat_model)
      content = RubyLLM::Content.new('Describe this', ['https://example.com/image.png'])

      expect(chat).to receive(:ask).with(
        'Describe this',
        with: [instance_of(URI::HTTPS)]
      )

      described_class.ask(chat, content)
    end

    it 'preserves non-string attachment sources for RubyLLM multimodal uploads' do
      allow(chat).to receive(:model).and_return(chat_model)
      io = StringIO.new('file-bytes')
      content = RubyLLM::Content.new('Process this file', [io])

      expect(chat).to receive(:ask).with('Process this file', with: [io])

      described_class.ask(chat, content)
    end

    it 'asks with text only when RubyLLM::Content has no attachments' do
      content = RubyLLM::Content.new('Just text')

      expect(chat).to receive(:ask).with('Just text')

      described_class.ask(chat, content)
    end

    it 'publishes a chat completion event when observability payload is provided' do
      events = []
      subscriber = ActiveSupport::Notifications.subscribe('llm.chat.complete') do |*args|
        events << ActiveSupport::Notifications::Event.new(*args)
      end
      response = double(
        'message',
        content: 'Hello back',
        input_tokens: 5,
        output_tokens: 7,
        tool_call?: false
      )
      allow(chat).to receive(:model).and_return(chat_model)
      allow(chat).to receive(:ask).with('Hello').and_return(response)

      result = described_class.ask(
        chat,
        'Hello',
        observability: { feature: 'copilot', account_id: 1 }
      )

      expect(result).to eq(response)
      expect(events.last.payload).to include(
        'feature' => 'copilot',
        'account_id' => 1,
        'model' => 'gpt-4.1-mini',
        'status' => 'success',
        'prompt_tokens' => 5,
        'completion_tokens' => 7,
        'total_tokens' => 12
      )
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
    end

    it 'raises when multimodal content is sent to a model without multimodal support' do
      allow(chat).to receive(:model).and_return(instance_double('RubyLLM::Model::Info', id: 'whisper-1'))
      content = RubyLLM::Content.new('Describe this', ['https://example.com/image.png'])

      expect do
        described_class.ask(chat, content)
      end.to raise_error(Llm::CapabilityPolicy::UnsupportedCapabilityError, /multimodal inputs/)
    end
  end
end
