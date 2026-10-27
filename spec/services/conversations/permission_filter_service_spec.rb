require 'rails_helper'

RSpec.describe Conversations::PermissionFilterService do
  let(:account) { create(:account) }
  let!(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let!(:another_conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let!(:inbox) { create(:inbox, account: account) }

  # This inbox_member is used to establish the agent's access to the inbox
  before { create(:inbox_member, user: agent, inbox: inbox) }

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
      it 'returns all conversations with no further filtering' do
        inbox_ids = agent.inboxes.where(account_id: account.id).pluck(:id)

        # The base implementation returns all conversations
        # expecting the caller to filter by assigned inboxes
        result = described_class.new(
          account.conversations.where(inbox_id: inbox_ids),
          agent,
          account
        ).perform

        expect(result).to include(conversation)
        expect(result).to include(another_conversation)
        expect(result.count).to eq(2)
      end
    end

    context 'when actor is a Captain assistant' do
      let!(:assistant) { create(:captain_assistant, account: account) }
      let(:other_inbox) { create(:inbox, account: account) }
      let!(:other_conversation) { create(:conversation, account: account, inbox: other_inbox) }

      before do
        create(:captain_inbox, inbox: inbox)
      end

      it 'returns the conversations of every inbox of the workspace: an agent is not tied to inboxes of its own' do
        result = described_class.new(account.conversations, assistant, account).perform

        expect(result).to include(conversation, another_conversation, other_conversation)
      end

      it 'returns nothing for an agent of another workspace, and for an internal assistant' do
        foreign = create(:captain_assistant)
        internal = create(:captain_assistant, account: account, usage_mode: 'internal_assistant')

        expect(described_class.new(account.conversations, foreign, account).perform).to be_empty
        expect(described_class.new(account.conversations, internal, account).perform).to be_empty
      end
    end
  end
end
