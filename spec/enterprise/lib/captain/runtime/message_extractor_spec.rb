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
          thinking: RubyLLM::Thinking.new(text: 'reasoning text', signature: 'sig_123'),
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
            thinking: 'reasoning text',
            thinking_signature: 'sig_123',
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

    it 'falls back to OpenRouter native reasoning fields when RubyLLM thinking is absent' do
      native_message = Struct.new(:role, :content, :tool_calls, :thinking, :reasoning, :reasoning_details, keyword_init: true) do
        def tool_call? = false
      end.new(
        role: :assistant,
        content: 'Done',
        tool_calls: {},
        reasoning: 'OpenRouter native reasoning text',
        reasoning_details: [{ 'type' => 'reasoning.text', 'text' => 'detail' }]
      )
      native_chat = Struct.new(:messages).new([native_message])

      extracted = described_class.extract_messages(native_chat, agent)

      expect(extracted.first).to include(
        role: :assistant,
        content: 'Done',
        thinking: 'OpenRouter native reasoning text',
        reasoning: 'OpenRouter native reasoning text',
        reasoning_details: [{ 'type' => 'reasoning.text', 'text' => 'detail' }]
      )
    end
  end
end
