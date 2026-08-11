require 'rails_helper'

describe Conversations::AssignmentService do
  let(:account) { create(:account) }
  let(:agent) { create(:user, account: account) }
  let(:agent_bot) { create(:agent_bot, account: account) }
  let(:conversation) { create(:conversation, account: account) }

  describe '#perform' do
    context 'when assignee_id is blank' do
      before do
        conversation.update!(assignee: agent, assignee_agent_bot: agent_bot)
      end

      it 'clears both human and bot assignees' do
        described_class.new(conversation: conversation, assignee_id: nil).perform

        conversation.reload
        expect(conversation.assignee_id).to be_nil
        expect(conversation.assignee_agent_bot_id).to be_nil
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
        conversation.update!(assignee_agent_bot: agent_bot, assignee: nil)
      end

      it 'sets the agent and clears agent bot' do
        result = described_class.new(conversation: conversation, assignee_id: agent.id).perform

        conversation.reload
        expect(result).to eq(agent)
        expect(conversation.assignee_id).to eq(agent.id)
        expect(conversation.assignee_agent_bot_id).to be_nil
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

    context 'when assigning an agent bot' do
      let(:service) do
        described_class.new(
          conversation: conversation,
          assignee_id: agent_bot.id,
          assignee_type: 'AgentBot'
        )
      end

      it 'sets the agent bot and clears human assignee' do
        conversation.update!(assignee: agent, assignee_agent_bot: nil)

        result = service.perform

        conversation.reload
        expect(result).to eq(agent_bot)
        expect(conversation.assignee_agent_bot_id).to eq(agent_bot.id)
        expect(conversation.assignee_id).to be_nil
      end
    end
  end
end
