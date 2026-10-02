require 'rails_helper'

RSpec.describe CommunicationThreads::RealtimeUpdateService do
  describe '#perform' do
    def expect_hidden_recipient_excluded(members, payload, hidden_user:, hidden_conversation:)
      expect(members).not_to include(hidden_user.pubsub_token)
      expect(payload[:conversation_ids]).not_to include(hidden_conversation.display_id)
    end

    it 'broadcasts the same shared unread state to each authorized operator' do
      account = create(:account).tap { |record| record.enable_features!('communication_threads') }
      inbox = create(:inbox, account: account)
      first_user = create(:user, account: account, role: :agent)
      second_user = create(:user, account: account, role: :agent)
      create(:inbox_member, inbox: inbox, user: first_user)
      create(:inbox_member, inbox: inbox, user: second_user)
      conversation = create(:conversation, account: account, inbox: inbox, agent_last_seen_at: 1.hour.ago)
      message = create(
        :message,
        account: account,
        inbox: inbox,
        conversation: conversation,
        message_type: :incoming,
        created_at: 5.minutes.ago
      )
      create(
        :conversation_user_read_state,
        account: account,
        conversation: conversation,
        user: first_user,
        last_seen_at: Time.current
      )
      create(
        :conversation_user_read_state,
        account: account,
        conversation: conversation,
        user: second_user,
        last_seen_at: 1.hour.ago
      )
      broadcasts = []
      allow(ActionCableBroadcastJob).to receive(:perform_later) { |members, event, payload| broadcasts << [members, event, payload] }
      expect(Scheduling::AppointmentDialogStatusContextBuilder).to receive(:new).once.and_call_original

      described_class.new(
        communication_thread_id: conversation.reload.communication_thread.id,
        source_conversation_id: conversation.id,
        source_event: 'message.created',
        message_id: message.id
      ).perform

      thread_broadcasts = broadcasts.select { |_members, event, _payload| event == 'communication_thread.updated' }
      expect(thread_broadcasts.size).to eq(1)
      members, _event, payload = thread_broadcasts.first
      expect(members).to contain_exactly(first_user.pubsub_token, second_user.pubsub_token)
      expect(payload).to include(unread_count: 1)
      expect(payload.fetch(:channels).first).to include(unread_count: 1)
    end

    it 'does not broadcast a source conversation hidden by a custom role' do
      account = create(:account).tap { |record| record.enable_features!('communication_threads') }
      inbox = create(:inbox, account: account)
      custom_role = create(:custom_role, account: account, permissions: [])
      restricted_user = create(:user, account: account, role: :agent)
      restricted_user.account_users.find_by(account: account).update!(custom_role: custom_role)
      create(:inbox_member, inbox: inbox, user: restricted_user)
      conversation = create(:conversation, account: account, inbox: inbox)
      broadcasts = []
      allow(ActionCableBroadcastJob).to receive(:perform_later) { |members, event, payload| broadcasts << [members, event, payload] }

      described_class.new(
        communication_thread_id: conversation.reload.communication_thread.id,
        source_conversation_id: conversation.id,
        source_event: 'conversation.updated'
      ).perform

      expect(broadcasts.none? { |members, _event, _payload| members.include?(restricted_user.pubsub_token) }).to be(true)
    end

    it 'broadcasts to authorized team members with only their visible linked channels' do
      account = create(:account).tap { |record| record.enable_features!('communication_threads') }
      contact = create(:contact, account: account)
      source_inbox = create(:inbox, account: account)
      hidden_inbox = create(:inbox, account: account)
      source_team = create(:team, account: account)
      hidden_team = create(:team, account: account)
      team_user = create(:user, account: account, role: :agent)
      hidden_inbox_user = create(:user, account: account, role: :agent)
      create(:team_member, team: source_team, user: team_user)
      create(:inbox_member, inbox: hidden_inbox, user: hidden_inbox_user)

      source_conversation = create(
        :conversation,
        account: account,
        contact: contact,
        inbox: source_inbox,
        team: source_team
      )
      hidden_conversation = create(
        :conversation,
        account: account,
        contact: contact,
        inbox: hidden_inbox,
        team: hidden_team
      )
      thread = source_conversation.reload.communication_thread
      expect(hidden_conversation.reload.communication_thread).to eq(thread)
      expect(team_user.inboxes).not_to include(source_inbox)
      user_context = {
        user: team_user,
        account: account,
        account_user: team_user.account_users.find_by!(account: account)
      }
      expect(ConversationPolicy.new(user_context, source_conversation).show?).to be(true)

      broadcasts = []
      allow(ActionCableBroadcastJob).to receive(:perform_later) { |members, event, payload| broadcasts << [members, event, payload] }

      described_class.new(
        communication_thread_id: thread.id,
        source_conversation_id: source_conversation.id,
        source_event: 'conversation.read'
      ).perform

      thread_broadcasts = broadcasts.select { |_members, event, _payload| event == 'communication_thread.updated' }
      expect(thread_broadcasts.size).to eq(1)
      members, _event, payload = thread_broadcasts.first
      expect(members).to contain_exactly(team_user.pubsub_token)
      expect(payload[:conversation_ids]).to contain_exactly(source_conversation.display_id)
      channel_conversation_ids = payload.fetch(:channels).map { |channel| channel[:conversation_id] }
      expect(channel_conversation_ids).to contain_exactly(source_conversation.display_id)
      expect_hidden_recipient_excluded(
        members, payload, hidden_user: hidden_inbox_user, hidden_conversation: hidden_conversation
      )
    end
  end
end
