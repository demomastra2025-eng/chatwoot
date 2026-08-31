# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CommunicationThreads::UpdateService do
  describe '#perform' do
    let(:account) do
      create(:account).tap { |record| record.enable_features!('communication_threads') }
    end

    def expected_routing_activity_contents(actor, assignee, team)
      [
        I18n.t('conversations.activity.status.pending', user_name: actor.name),
        I18n.t(
          'conversations.activity.priority.updated', old_priority: 'low', new_priority: 'urgent', user_name: actor.name
        ),
        I18n.t(
          'conversations.activity.team.assigned_with_assignee',
          assignee_name: assignee.name, team_name: team.name, user_name: actor.name
        ),
        I18n.t('conversations.activity.assignee.assigned', assignee_name: assignee.name, user_name: actor.name)
      ]
    end

    it 'syncs thread status, priority and routing fields to accessible child conversations' do
      team = create(:team, account: account)
      actor = create(:user, account: account)
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

      expect(Conversations::CommunicationThreadResolver).to receive(:new).at_least(:once).and_call_original
      Current.user = actor

      thread = perform_enqueued_jobs do
        described_class.new(
          communication_thread: conversation.reload.communication_thread,
          params: params,
          accessible_links: CommunicationThreadConversation.where(id: link.id),
          actor: actor
        ).perform
      end

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
      expect(conversation.messages.activity.pluck(:content)).to include(*expected_routing_activity_contents(actor, assignee, team))
    ensure
      Current.user = nil
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

    it 'rolls back conversation changes when the thread refresh fails' do
      conversation = create(:conversation, account: account, priority: :low)
      link = conversation.communication_thread_conversation
      params = ActionController::Parameters.new(priority: 'urgent').permit!
      service = described_class.new(
        communication_thread: conversation.reload.communication_thread,
        params: params,
        accessible_links: CommunicationThreadConversation.where(id: link.id)
      )
      resolver = instance_double(Conversations::CommunicationThreadResolver)
      allow(Conversations::CommunicationThreadResolver).to receive(:new).and_return(resolver)
      allow(resolver).to receive(:perform).and_raise(ActiveRecord::Deadlocked)

      expect { service.perform }.to raise_error(ActiveRecord::Deadlocked)
      expect(conversation.reload).to have_attributes(priority: 'low')
    end

    it 'assigns one stable event id while syncing child conversations' do
      conversation = create(:conversation, account: account)
      service = described_class.new(
        communication_thread: conversation.reload.communication_thread,
        params: ActionController::Parameters.new.permit!,
        accessible_links: CommunicationThreadConversation.none
      )

      service.send(:sync_conversation!, conversation)
      first_event_id = conversation.communication_thread_event_id
      service.send(:sync_conversation!, conversation)

      expect(first_event_id).to be_present
      expect(conversation.communication_thread_event_id).to eq(first_event_id)
    end

    it 'queues one aggregate realtime refresh for a multi-conversation update' do
      contact = create(:contact, account: account)
      first_conversation = create(:conversation, account: account, contact: contact, status: :open)
      create(:conversation, account: account, contact: contact, status: :open)
      thread = first_conversation.reload.communication_thread
      links = thread.communication_thread_conversations.order(:id)
      actor = create(:user, account: account)
      allow(CommunicationThreads::RealtimeUpdateJob).to receive(:perform_later)

      described_class.new(
        communication_thread: thread,
        params: ActionController::Parameters.new(status: 'resolved').permit!,
        accessible_links: links,
        actor: actor
      ).perform

      expect(CommunicationThreads::RealtimeUpdateJob).to have_received(:perform_later).once.with(
        communication_thread_id: thread.id,
        source_conversation_id: first_conversation.id,
        source_event: 'conversation.status_changed',
        performer_id: actor.id
      )
    end
  end
end
