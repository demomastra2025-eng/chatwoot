require 'rails_helper'

RSpec.describe CommunicationThreads::RealtimeUpdateService do
  describe '#perform' do
    it 'broadcasts user-specific unread state without clearing another operator' do
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

      first_payload = broadcasts.find { |members, _event, _payload| members == [first_user.pubsub_token] }.last
      second_payload = broadcasts.find { |members, _event, _payload| members == [second_user.pubsub_token] }.last
      expect(first_payload).to include(unread_count: 0)
      expect(first_payload.fetch(:channels).first).to include(unread_count: 0)
      expect(second_payload).to include(unread_count: 1)
      expect(second_payload.fetch(:channels).first).to include(unread_count: 1)
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
  end
end
