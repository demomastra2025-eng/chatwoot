require 'rails_helper'

RSpec.describe Captain::Tools::Copilot::GetConversationService do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:service) { described_class.new(assistant, user: user) }

  describe '#name' do
    it 'returns the correct service name' do
      expect(service.name).to eq('get_conversation')
    end
  end

  describe '#active?' do
    context 'when user is an admin' do
      let(:user) { create(:user, :administrator, account: account) }

      it 'returns true' do
        expect(service.active?).to be true
      end
    end

    context 'when user has custom role without any conversation permissions' do
      let(:custom_role) { create(:custom_role, account: account, permissions: []) }

      before do
        account_user = AccountUser.find_by(user: user, account: account)
        account_user.update(role: :agent, custom_role: custom_role)
      end

      it 'returns false' do
        expect(service.active?).to be false
      end
    end
  end

  describe '#execute' do
    let(:user) { create(:user, :administrator, account: account) }

    it 'returns not found message when conversation is missing' do
      expect(service.execute(conversation_id: 999)).to eq('ERROR: Conversation not found')
    end

    it 'returns a normalized conversation payload including messages' do
      inbox = create(:inbox, account: account)
      conversation = create(:conversation, account: account, inbox: inbox)
      create(:message,
             conversation: conversation,
             message_type: 'outgoing',
             content: 'Regular message',
             private: false)
      create(:message,
             conversation: conversation,
             message_type: 'outgoing',
             content: 'Private note content',
             private: true)

      payload = JSON.parse(service.execute(conversation_id: conversation.display_id))
      conversation_payload = payload.fetch('conversation')
      contents = conversation_payload.fetch('messages').map { |message| message['content'] }
      private_note = conversation_payload.fetch('messages').find { |message| message['private'] }

      expect(conversation_payload).to include(
        'id' => conversation.id,
        'display_id' => conversation.display_id,
        'status' => conversation.status,
        'inbox_id' => inbox.id,
        'inbox_name' => inbox.name,
        'contact_id' => conversation.contact_id,
        'contact_name' => conversation.contact.name
      )
      expect(contents).to contain_exactly('Regular message')
      expect(private_note).to be_nil
      expect(conversation_payload['message_window']).to include(
        'limit' => 20,
        'returned_count' => 1,
        'truncated' => false,
        'private_messages_included' => false
      )
    end

    it 'includes private notes only when an administrator explicitly requests them' do
      conversation = create(:conversation, account: account)
      create(:message, conversation: conversation, content: 'Private note content', private: true)

      payload = JSON.parse(service.execute(conversation_id: conversation.display_id, include_private: true))

      expect(payload.dig('conversation', 'messages').sole).to include('content' => 'Private note content', 'private' => true)
      expect(payload.dig('conversation', 'message_window', 'private_messages_included')).to be true
    end

    it 'returns only the latest bounded message window' do
      conversation = create(:conversation, account: account)
      messages = Array.new(3) do |index|
        create(:message, conversation: conversation, content: "Message #{index}")
      end
      messages.each_with_index { |message, index| message.update!(created_at: 3.minutes.ago + index.minutes) }

      payload = JSON.parse(service.execute(conversation_id: conversation.display_id, message_limit: 2))

      expect(payload.dig('conversation', 'messages').pluck('content')).to eq(['Message 1', 'Message 2'])
      expect(payload.dig('conversation', 'message_window')).to include('limit' => 2, 'returned_count' => 2, 'truncated' => true)
    end

    context 'when a non-administrator requests private notes' do
      let(:user) { create(:user, account: account) }

      it 'fails closed before loading conversation messages' do
        expect(service.execute(conversation_id: 1, include_private: true)).to eq(
          'ERROR: Account administrator permission is required to include private notes'
        )
      end
    end
  end
end
