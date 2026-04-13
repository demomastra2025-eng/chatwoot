# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Runtime::MessageExtractor do
  describe '.extract_messages' do
    let(:agent) { instance_double(Captain::Runtime::Agent, name: 'assistant_agent') }
    let(:chat) { Struct.new(:messages).new(messages) }

    let(:messages) do
      [
        RubyLLM::Message.new(role: :user, content: 'Hello'),
        RubyLLM::Message.new(
          role: :assistant,
          content: '',
          tool_calls: {
            'call_1' => RubyLLM::ToolCall.new(id: 'call_1', name: 'search_faq', arguments: { query: 'refund' })
          }
        ),
        RubyLLM::Message.new(role: :tool, content: 'FAQ result', tool_call_id: 'call_1')
      ]
    end

    it 'extracts assistant attribution, tool calls, and tool results' do
      extracted = described_class.extract_messages(chat, agent)

      expect(extracted).to eq(
        [
          { role: :user, content: 'Hello' },
          {
            role: :assistant,
            content: '',
            agent_name: 'assistant_agent',
            tool_calls: [
              { id: 'call_1', name: 'search_faq', arguments: { query: 'refund' } }
            ]
          },
          { role: :tool, content: 'FAQ result', tool_call_id: 'call_1' }
        ]
      )
    end

    it 'serializes multimodal RubyLLM::Content into persisted content parts' do
      multimodal_chat = Struct.new(:messages).new(
        [
          RubyLLM::Message.new(
            role: :user,
            content: RubyLLM::Content.new('Look', ['https://example.com/image.png'])
          )
        ]
      )

      extracted = described_class.extract_messages(multimodal_chat, agent)

      expect(extracted).to eq(
        [
          {
            role: :user,
            content: [
              { type: 'text', text: 'Look' },
              { type: 'image_url', image_url: { url: 'https://example.com/image.png' } }
            ]
          }
        ]
      )
    end
  end
end
