# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::MessageFormat do
  describe '.build_message_params' do
    it 'keeps plain tool results as strings' do
      params = described_class.build_message_params(
        {
          'role' => 'tool',
          'content' => 'Lookup finished',
          'tool_call_id' => 'call_1'
        }
      )

      expect(params).to include(role: :tool, content: 'Lookup finished', tool_call_id: 'call_1')
    end

    it 'restores multimodal assistant content as RubyLLM::Content with attachments' do
      params = described_class.build_message_params(
        {
          role: :assistant,
          content: [
            { type: 'text', text: 'Please inspect this screenshot' },
            { type: 'image_url', image_url: { url: 'https://example.com/error.png' } }
          ]
        }
      )

      expect(params[:content]).to be_a(RubyLLM::Content)
      expect(params[:content].text).to eq('Please inspect this screenshot')
      expect(params[:content].attachments.first.source.to_s).to eq('https://example.com/error.png')
    end

    it 'restores assistant thinking details for provider continuity' do
      params = described_class.build_message_params(
        {
          role: :assistant,
          content: 'Done',
          thinking: 'internal reasoning',
          thinking_signature: 'sig_123'
        }
      )

      expect(params[:thinking]).to be_a(RubyLLM::Thinking)
      expect(params[:thinking].text).to eq('internal reasoning')
      expect(params[:thinking].signature).to eq('sig_123')
    end
  end

  describe '.restore_messages' do
    it 'skips tool results that do not match a preceding assistant tool call' do
      chat = Struct.new(:messages) do
        def add_message(message)
          messages << message
        end
      end.new([])

      described_class.restore_messages(
        chat,
        [
          { role: :tool, content: 'No matching tool call', tool_call_id: 'missing_call' },
          { role: :user, content: 'Hello' }
        ]
      )

      expect(chat.messages.map(&:role)).to eq([:user])
      expect(chat.messages.first.content).to eq('Hello')
    end
  end

  describe '.serialize_content' do
    it 'serializes RubyLLM::Content into persisted multimodal parts' do
      payload = described_class.serialize_content(
        RubyLLM::Content.new('Look', ['https://example.com/image.png'])
      )

      expect(payload).to eq(
        [
          { type: 'text', text: 'Look' },
          { type: 'image_url', image_url: { url: 'https://example.com/image.png' } }
        ]
      )
    end
  end
end
