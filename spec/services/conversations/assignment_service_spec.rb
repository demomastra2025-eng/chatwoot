require 'rails_helper'

describe Conversations::AssignmentService do
  let(:account) { create(:account) }
  let(:agent) { create(:user, account: account) }
  let(:conversation) { create(:conversation, account: account) }

  describe '#perform' do
    context 'when assignee_id is blank' do
      before do
        conversation.update!(assignee: agent)
      end

      it 'clears the assignee' do
        described_class.new(conversation: conversation, assignee_id: nil).perform

        expect(conversation.reload.assignee_id).to be_nil
      end

      it 'persists an unassignment activity for the acting user' do
        actor = create(:user, account: account)
        Current.user = actor

        perform_enqueued_jobs(only: Conversations::ActivityMessageJob) do
          described_class.new(conversation: conversation, assignee_id: nil).perform
        end

        expect(conversation.messages.activity.last.content).to eq(
          I18n.t('conversations.activity.assignee.removed', user_name: actor.name, assignee_name: '')
        )
      ensure
        Current.user = nil
      end
    end

    context 'when assigning a user' do
      before do
        conversation.update!(assignee: nil)
      end

      it 'sets the agent' do
        result = described_class.new(conversation: conversation, assignee_id: agent.id).perform

        expect(result).to eq(agent)
        expect(conversation.reload.assignee_id).to eq(agent.id)
      end

      it 'does not assign a user of another account' do
        stranger = create(:user)

        result = described_class.new(conversation: conversation, assignee_id: stranger.id).perform

        expect(result).to be_nil
        expect(conversation.reload.assignee_id).to be_nil
      end

      it 'persists an assignment activity for the acting user' do
        actor = create(:user, account: account)
        Current.user = actor

        perform_enqueued_jobs(only: Conversations::ActivityMessageJob) do
          described_class.new(conversation: conversation, assignee_id: agent.id).perform
        end

        expect(conversation.messages.activity.last.content).to eq(
          I18n.t(
            'conversations.activity.assignee.assigned',
            assignee_name: agent.name,
            user_name: actor.name
          )
        )
      ensure
        Current.user = nil
      end
    end
  end
end
