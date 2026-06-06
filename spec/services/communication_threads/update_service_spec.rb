# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CommunicationThreads::UpdateService do
  describe '#perform' do
    let(:account) do
      create(:account).tap { |record| record.enable_features!('communication_threads') }
    end

    it 'syncs thread status, priority and routing fields to accessible child conversations' do
      team = create(:team, account: account)
      assignee = create(:user, account: account)
      create(:team_member, team: team, user: assignee)
      conversation = create(:conversation, account: account, status: :open, priority: :low)
      link = conversation.communication_thread_conversation
      params = ActionController::Parameters.new(
        status: 'pending',
        priority: 'urgent',
        assignee_id: assignee.id,
        team_id: team.id
      ).permit!

      thread = described_class.new(
        communication_thread: conversation.reload.communication_thread,
        params: params,
        accessible_links: CommunicationThreadConversation.where(id: link.id)
      ).perform

      expect(conversation.reload).to have_attributes(
        status: 'pending',
        priority: 'urgent',
        assignee_id: assignee.id,
        team_id: team.id
      )
      expect(thread).to have_attributes(
        status: 'pending',
        priority: 'urgent',
        assignee_id: assignee.id,
        team_id: team.id
      )
    end

    it 'keeps inaccessible child conversations unchanged and aggregates the real thread status' do
      contact = create(:contact, account: account)
      accessible_conversation = create(:conversation, account: account, contact: contact, status: :open)
      inaccessible_conversation = create(:conversation, account: account, contact: contact, status: :open)
      params = ActionController::Parameters.new(status: 'resolved').permit!

      thread = described_class.new(
        communication_thread: accessible_conversation.reload.communication_thread,
        params: params,
        accessible_links: CommunicationThreadConversation.where(conversation_id: accessible_conversation.id)
      ).perform

      expect(accessible_conversation.reload).to be_resolved
      expect(inaccessible_conversation.reload).to be_open
      expect(thread).to be_open
    end
  end
end
