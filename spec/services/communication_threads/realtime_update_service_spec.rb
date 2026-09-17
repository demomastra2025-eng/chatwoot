# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CommunicationThreads::RealtimeUpdateService do
  let(:account) { create(:account).tap { |record| record.enable_features!('communication_threads') } }
  let(:participant) { create(:user, account: account) }
  let(:contact) { create(:contact, account: account) }
  let!(:first_conversation) { create(:conversation, account: account, contact: contact) }
  let(:second_conversation) { create(:conversation, account: account, contact: contact) }
  let(:communication_thread) { first_conversation.reload.communication_thread }
  let(:links) do
    second_conversation
    communication_thread.communication_thread_conversations.to_a
  end
  let(:service) do
    described_class.new(
      communication_thread_id: communication_thread.id,
      source_conversation_id: first_conversation.id,
      source_event: 'message.created'
    )
  end

  it 'exposes every linked channel to a canonical participant' do
    policy = instance_double(CommunicationThreadPolicy, show?: false)

    visible_links = service.send(:recipient_visible_links, participant, links, [participant.id], policy)

    expect(visible_links).to match_array(links)
    expect(policy).not_to have_received(:show?)
  end

  it 'suppresses realtime links when canonical thread policy denies access' do
    policy = instance_double(CommunicationThreadPolicy, show?: false)

    visible_links = service.send(:recipient_visible_links, participant, links, [], policy)

    expect(visible_links).to be_empty
  end

  it 'sends a final revocation payload to an explicitly targeted removed participant' do
    targeted_service = described_class.new(
      communication_thread_id: communication_thread.id,
      source_conversation_id: first_conversation.id,
      source_event: 'participant.removed',
      recipient_user_ids: [participant.id]
    )
    policy = instance_double(CommunicationThreadPolicy, show?: false)

    visible_links = targeted_service.send(:recipient_visible_links, participant, links, [], policy)

    expect(visible_links).to match_array(links)
    expect(policy).not_to have_received(:show?)
  end
end

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
