require 'rails_helper'

describe Conversations::AssignmentService do
  let(:account) { create(:account).tap { |record| record.enable_features!('communication_threads') } }
  let(:agent) { create(:user, account: account) }
  let(:conversation) { create(:conversation, account: account) }

  describe '#perform' do
    context 'when assignee_id is blank' do
      before do
        conversation.update!(assignee: agent)
      end

      it 'clears the human assignee' do
        described_class.new(conversation: conversation, assignee_id: nil).perform

        conversation.reload
        expect(conversation.assignee_id).to be_nil
        expect(conversation.contact.reload.owner_id).to be_nil
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

        conversation.reload
        expect(result).to eq(agent)
        expect(conversation.assignee_id).to eq(agent.id)
        expect(conversation.contact.reload.owner).to eq(agent)
      end

      it 'assigns every channel conversation and communication thread for the contact' do
        contact = create(:contact, account: account)
        first_conversation = create(:conversation, account: account, contact: contact, assignee: nil)
        second_conversation = create(:conversation, account: account, contact: contact, assignee: nil)

        described_class.new(conversation: first_conversation, assignee_id: agent.id).perform

        expect(contact.reload.owner).to eq(agent)
        expect(contact.conversations.reload.pluck(:assignee_id).uniq).to eq([agent.id])
        expect(contact.communication_threads.reload.pluck(:assignee_id).uniq).to eq([agent.id])
        expect(second_conversation.reload.assignee).to eq(agent)
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

    it 'atomically applies an agent and team to every channel projection' do
      contact = create(:contact, account: account)
      team = create(:team, account: account)
      first_conversation = create(:conversation, account: account, contact: contact, assignee: nil, team: nil)
      second_conversation = create(:conversation, account: account, contact: contact, assignee: nil, team: nil)

      described_class.new(
        conversation: first_conversation,
        assignee_id: agent.id,
        team_id: team.id
      ).perform

      expect(contact.reload.owner).to eq(agent)
      expect(contact.conversations.reload.pluck(:assignee_id).uniq).to eq([agent.id])
      expect(contact.conversations.reload.pluck(:team_id).uniq).to eq([team.id])
      expect(contact.communication_threads.reload.pluck(:assignee_id).uniq).to eq([agent.id])
      expect(contact.communication_threads.reload.pluck(:team_id).uniq).to eq([team.id])
      expect(second_conversation.reload).to have_attributes(assignee_id: agent.id, team_id: team.id)
    end

    it 'rejects retired non-user assignee types' do
      expect do
        described_class.new(conversation: conversation, assignee_id: agent.id, assignee_type: 'AgentBot').perform
      end.to raise_error(ArgumentError, 'assignee_type must be User')
    end

  end
end
