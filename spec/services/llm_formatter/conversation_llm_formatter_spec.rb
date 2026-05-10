require 'rails_helper'

RSpec.describe LlmFormatter::ConversationLlmFormatter do
  let(:account) { create(:account) }
  let(:conversation) { create(:conversation, account: account) }
  let(:formatter) { described_class.new(conversation) }

  describe '#format' do
    context 'when conversation has no messages' do
      it 'returns basic conversation info with no messages' do
        expected_output = [
          "Conversation ID: ##{conversation.display_id}",
          "Channel: #{conversation.inbox.channel.name}",
          'Message History:',
          'No messages in this conversation'
        ].join("\n")

        expect(formatter.format).to eq(expected_output)
      end
    end

    context 'when conversation has messages' do
      it 'formats messages in chronological order with sender labels' do
        create(
          :message,
          conversation: conversation,
          message_type: 'incoming',
          content: 'Hello, I need help'
        )

        create(
          :message,
          :bot_message,
          conversation: conversation,
          message_type: 'outgoing',
          content: 'Thanks for reaching out, an agent will reach out to you soon'
        )

        create(
          :message,
          conversation: conversation,
          message_type: 'outgoing',
          content: 'How can I assist you today?'
        )

        expected_output = [
          "Conversation ID: ##{conversation.display_id}",
          "Channel: #{conversation.inbox.channel.name}",
          'Message History:',
          'User: Hello, I need help',
          'Bot: Thanks for reaching out, an agent will reach out to you soon',
          'Support Agent: How can I assist you today?',
          ''
        ].join("\n")

        expect(formatter.format).to eq(expected_output)
      end
    end

    context 'when conversation has a voice call transcript' do
      it 'formats the transcript as voice-specific LLM context instead of a normal chat message' do
        create(
          :message,
          conversation: conversation,
          inbox: conversation.inbox,
          message_type: :incoming,
          content_type: :voice_call,
          content: 'Voice Call',
          content_attributes: {
            data: {
              call_sid: 'voice-call-llm-1',
              transcript_items: [
                { speaker: 'caller', text: 'Хочу узнать тариф', final: true },
                { speaker: 'ai', text: 'Тариф начинается от 1000 тенге', final: true }
              ]
            }
          }
        )

        output = formatter.format

        expect(output).to include('Voice Call Transcripts:')
        expect(output).to include('Call voice-call-llm-1:')
        expect(output).to include('User: Хочу узнать тариф')
        expect(output).to include('AI Voice Agent: Тариф начинается от 1000 тенге')
        expect(output).not_to include('User: Voice Call')
      end

      it 'formats transcript from call-session metadata when no voice bubble exists yet' do
        create(
          :telephony_call_session,
          account: account,
          conversation: conversation,
          inbox: conversation.inbox,
          external_call_ref: 'voice-call-metadata-1',
          metadata: {
            'ai_voice' => {
              'transcript' => {
                'final_items' => [
                  { 'speaker' => 'caller', 'text' => 'Можно доставку завтра?' },
                  { 'speaker' => 'ai', 'text' => 'Да, оформим доставку на завтра.' }
                ]
              }
            }
          }
        )

        output = formatter.format

        expect(output).to include('Call voice-call-metadata-1:')
        expect(output).to include('User: Можно доставку завтра?')
        expect(output).to include('AI Voice Agent: Да, оформим доставку на завтра.')
      end
    end

    context 'when include_contact_details is true' do
      it 'includes contact details' do
        expected_output = [
          "Conversation ID: ##{conversation.display_id}",
          "Channel: #{conversation.inbox.channel.name}",
          'Message History:',
          'No messages in this conversation',
          "Contact Details: #{conversation.contact.to_llm_text}"
        ].join("\n")

        expect(formatter.format(include_contact_details: true)).to eq(expected_output)
      end
    end

    context 'when conversation has custom attributes' do
      it 'includes formatted custom attributes in the output' do
        create(
          :custom_attribute_definition,
          account: account,
          attribute_display_name: 'Order ID',
          attribute_key: 'order_id',
          attribute_model: :conversation_attribute
        )

        conversation.update(custom_attributes: { 'order_id' => '12345' })

        expected_output = [
          "Conversation ID: ##{conversation.display_id}",
          "Channel: #{conversation.inbox.channel.name}",
          'Message History:',
          'No messages in this conversation',
          'Conversation Attributes:',
          'Order ID: 12345'
        ].join("\n")

        expect(formatter.format).to eq(expected_output)
      end
    end
  end
end
