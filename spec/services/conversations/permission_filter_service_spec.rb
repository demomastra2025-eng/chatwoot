require 'rails_helper'

RSpec.describe Conversations::PermissionFilterService do
  let(:account) { create(:account) }
  let!(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let!(:another_conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let!(:inbox) { create(:inbox, account: account) }

  describe '#perform' do
    context 'when user is an administrator' do
      it 'returns all conversations' do
        result = described_class.new(
          account.conversations,
          admin,
          account
        ).perform

        expect(result).to include(conversation)
        expect(result).to include(another_conversation)
        expect(result.count).to eq(2)
      end
    end

    context 'when user is an agent' do
      let(:other_inbox) { create(:inbox, account: account) }
      let!(:other_conversation) { create(:conversation, account: account, inbox: other_inbox) }
      let(:voice_inbox) { create(:channel_voice, :sipuni, account: account).inbox }
      let!(:voice_conversation) { create(:conversation, account: account, inbox: voice_inbox) }

      it 'returns every messaging conversation but only assigned Voice conversations' do
        result = described_class.new(
          account.conversations,
          agent,
          account
        ).perform

        expect(result).to include(conversation)
        expect(result).to include(another_conversation)
        expect(result).to include(other_conversation)
        expect(result).not_to include(voice_conversation)
        expect(result.count).to eq(3)

        create(:inbox_member, user: agent, inbox: voice_inbox)

        expect(described_class.new(account.conversations, agent, account).perform).to include(voice_conversation)
      end
    end

    context 'when user does not belong to the account' do
      let(:outsider) { create(:user) }

      it 'returns no conversations' do
        result = described_class.new(account.conversations, outsider, account).perform

        expect(result).to be_empty
      end
    end

    context 'when actor is a Captain assistant' do
      let(:assistant) { create(:captain_assistant, account: account) }
      let(:other_inbox) { create(:inbox, account: account) }
      let!(:other_conversation) { create(:conversation, account: account, inbox: other_inbox) }

      before do
        create(:captain_inbox, captain_assistant: assistant, inbox: inbox)
      end

      it 'returns conversations from the assistant connected inboxes only' do
        result = described_class.new(account.conversations, assistant, account).perform

        expect(result).to include(conversation)
        expect(result).to include(another_conversation)
        expect(result).not_to include(other_conversation)
      end
    end
  end
end
