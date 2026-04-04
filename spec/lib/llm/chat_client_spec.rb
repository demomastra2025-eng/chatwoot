# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::ChatClient do
  let(:chat) { instance_double(RubyLLM::Chat) }
  let(:context) { instance_double(RubyLLM::Context, chat: chat) }

  describe '.build' do
    before do
      allow(chat).to receive(:with_temperature).and_return(chat)
      allow(chat).to receive(:with_params).and_return(chat)
      allow(chat).to receive(:with_headers).and_return(chat)
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

    it 'reuses an existing chat instance when provided' do
      expect(RubyLLM).not_to receive(:chat)
      expect(context).not_to receive(:chat)

      result = described_class.build(chat: chat, model: 'ignored')

      expect(result).to eq(chat)
    end
  end

  describe '.ask' do
    it 'asks with plain content directly' do
      expect(chat).to receive(:ask).with('Hello')

      described_class.ask(chat, 'Hello')
    end

    it 'asks with multimodal content attachments when present' do
      content = RubyLLM::Content.new('Describe this', ['https://example.com/image.png'])

      expect(chat).to receive(:ask).with('Describe this', with: ['https://example.com/image.png'])

      described_class.ask(chat, content)
    end

    it 'asks with text only when RubyLLM::Content has no attachments' do
      content = RubyLLM::Content.new('Just text')

      expect(chat).to receive(:ask).with('Just text')

      described_class.ask(chat, content)
    end
  end
end
