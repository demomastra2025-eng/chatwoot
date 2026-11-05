# frozen_string_literal: true

require 'rails_helper'

RSpec.describe TelegramPersonal::IncomingCallService do
  include ActiveJob::TestHelper

  let(:account) { create(:account).tap { |record| record.enable_features!('communication_threads') } }
  let(:channel) { create(:channel_telegram_personal, account: account) }
  let(:inbox) { channel.inbox }

  around do |example|
    with_modified_env(
      'FRONTEND_URL' => 'https://app.example.com',
      'TELEGRAM_PERSONAL_GATEWAY_URL' => 'http://gateway.internal:8790',
      'TELEGRAM_PERSONAL_GATEWAY_TOKEN' => 'secret-token'
    ) do
      example.run
    end
  end

  before do
    Current.suppress_runtime_events = true
    Conversation.skip_callback(:create, :before, :determine_conversation_status)
    Conversation.skip_callback(:commit, :after, :notify_conversation_creation)
  end

  after do
    Conversation.set_callback(:commit, :after, :notify_conversation_creation, on: :create)
    Conversation.set_callback(:create, :before, :determine_conversation_status)
    Current.suppress_runtime_events = nil
  end

  describe 'Channel::TelegramPersonal calling capability and Call.media_server_enabled?' do
    it 'defaults calling_enabled? to true and persists false across runtime_state normalization' do
      expect(channel.calling_enabled?).to be(true)
      expect(channel.voice_enabled?).to be(true)
      expect(Call.media_server_enabled?(inbox: inbox)).to be(true)

      channel.update!(calling_enabled: false)
      channel.reload

      expect(channel.calling_enabled?).to be(false)
      expect(channel.runtime_state['calling_enabled']).to be(false)
    end
  end

  describe 'TelegramPersonal::IncomingEventService routing' do
    it 'dispatches call.incoming, call.accepted, and call.ended to TelegramPersonal::IncomingCallService' do
      %w[call.incoming call.accepted call.ended].each do |event_name|
        call_service = instance_double(described_class, perform: true)
        allow(described_class).to receive(:new).and_return(call_service)

        TelegramPersonal::IncomingEventService.new(
          channel: channel,
          payload: {
            event: event_name,
            telegram_personal: { data: { call_id: 'tg-900', peer_user_id: '501' } }
          }
        ).perform

        expect(described_class).to have_received(:new).with(
          inbox: inbox,
          event: event_name,
          params: { call_id: 'tg-900', peer_user_id: '501' }
        )
        expect(call_service).to have_received(:perform)
      end
    end
  end

  describe '#perform' do
    let(:incoming_params) do
      {
        call_id: 'tg-call-101',
        session_id: 'tg-sess-101',
        peer_user_id: '42001',
        chat_id: '42001',
        sender_id: '42001',
        chat_type: 'private',
        first_name: 'Arman',
        last_name: 'K.',
        username: 'arman_k',
        phone_number: '+77015550101',
        agent_offer: {
          sdp_offer: "v=0\r\nlegacy-incoming\r\n",
          ice_servers: [{ urls: 'stun:stun.example.com' }],
          peer_id: 'peer-b-1'
        }
      }
    end

    it 'creates an incoming Call and voice_call message' do
      allow(ActionCable.server).to receive(:broadcast)

      expect do
        described_class.new(inbox: inbox, event: 'call.incoming', params: incoming_params).perform
      end.to change(Call.telegram_personal, :count).by(1)

      call = Call.telegram_personal.last
      expect(call.provider_call_id).to eq('tg-call-101')
      expect(call.media_session_id).to eq('tg-sess-101')
      expect(call.direction).to eq('incoming')
      expect(call.status).to eq('ringing')
      expect(call.meta.dig('agent_offer', 'peer_id')).to eq('peer-b-1')
    end

    it 'links a voice_call message, schedules cleanup, and broadcasts incoming call' do
      allow(ActionCable.server).to receive(:broadcast)

      expect do
        described_class.new(inbox: inbox, event: 'call.incoming', params: incoming_params).perform
      end.to have_enqueued_job(TelegramPersonal::CallCleanupJob)

      call = Call.telegram_personal.last
      expect(call.message&.content_type).to eq('voice_call')
      expect(call.message.content_attributes.dig('data', 'call_source')).to eq('telegram_personal')
      expect(call.conversation.additional_attributes['call_status']).to eq('ringing')

      expect(ActionCable.server).to have_received(:broadcast).with(
        "account_#{account.id}",
        hash_including(
          event: 'telegram_personal_call.incoming',
          data: hash_including(
            id: call.id,
            call_id: 'tg-call-101',
            provider: 'telegram_personal',
            media_server_enabled: true
          )
        )
      )
      expect(ActionCable.server).not_to have_received(:broadcast).with(
        anything,
        hash_including(event: 'telegram_personal_call.incoming', data: hash_including(agent_offer: anything))
      )
    end

    it 'skips incoming calls when calling_enabled is false on the channel' do
      channel.update!(calling_enabled: false)

      expect do
        described_class.new(inbox: inbox, event: 'call.incoming', params: incoming_params).perform
      end.not_to change(Call, :count)
    end

    it 'upgrades pending provider_call_id via session_id and marks outbound call in_progress on call.accepted' do
      contact = create(:contact, account: account)
      contact_inbox = create(:contact_inbox, contact: contact, inbox: inbox, source_id: '42001')
      conversation = create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox)
      agent = create(:user, account: account, role: :agent)
      call = Call.create!(
        provider: :telegram_personal,
        account: account,
        inbox: inbox,
        conversation: conversation,
        contact: contact,
        provider_call_id: 'pending_sess-out-1',
        media_session_id: 'sess-out-1',
        direction: :outgoing,
        status: 'ringing',
        accepted_by_agent: agent
      )
      message = TelegramPersonal::CallMessageBuilder.create!(conversation: conversation, call: call, user: agent)
      call.update!(message_id: message.id)
      allow(ActionCable.server).to receive(:broadcast)

      described_class.new(
        inbox: inbox,
        event: 'call.accepted',
        params: { call_id: '99887766', session_id: 'sess-out-1' }
      ).perform

      call.reload
      expect(call.provider_call_id).to eq('99887766')
      expect(call.status).to eq('in_progress')
      expect(call.started_at).to be_present
      expect(call.message.reload.source_id).to eq('tg_call_99887766')
      expect(ActionCable.server).to have_received(:broadcast).with(
        "account_#{account.id}",
        hash_including(event: 'telegram_personal_call.outbound_accepted')
      )
    end

    it 'finalizes ended calls, broadcasts ended event, and enqueues recording fetch' do
      described_class.new(inbox: inbox, event: 'call.incoming', params: incoming_params).perform
      call = Call.telegram_personal.last
      call.update!(status: 'in_progress', started_at: 20.seconds.ago)
      allow(ActionCable.server).to receive(:broadcast)

      expect do
        described_class.new(
          inbox: inbox,
          event: 'call.ended',
          params: {
            call_id: 'tg-call-101',
            session_id: 'tg-sess-101',
            duration_seconds: 21,
            end_reason: 'hangup',
            has_recording: true
          }
        ).perform
      end.to have_enqueued_job(TelegramPersonal::CallRecordingFetchJob).with(call.id)

      call.reload
      expect(call.status).to eq('completed')
      expect(call.duration_seconds).to eq(21)
      expect(call.message.reload.content_attributes.dig('data', 'status')).to eq('completed')
      expect(ActionCable.server).to have_received(:broadcast).with(
        "account_#{account.id}",
        hash_including(event: 'telegram_personal_call.ended')
      )
    end

    it 'suppresses duplicate plain *_voice_call activity messages when an interactive voice_call message exists' do
      described_class.new(inbox: inbox, event: 'call.incoming', params: incoming_params).perform
      call = Call.telegram_personal.last

      expect do
        TelegramPersonal::CreateActivityMessageService.new(
          inbox: inbox,
          params: {
            message_id: 'act-555',
            peer_user_id: '42001',
            chat_id: '42001',
            sender_id: '42001',
            chat_type: 'private',
            activity_code: 'missed_voice_call',
            text: 'Missed voice call'
          }
        ).perform
      end.not_to(change { call.conversation.messages.where.not(content_type: 'voice_call').count })
    end
  end

  describe 'CommunicationThreads::ChannelCapabilitiesBuilder integration' do
    it 'marks private Telegram Personal chats can_call: true and group chats can_call: false' do
      contact = create(:contact, account: account)
      private_ci = create(:contact_inbox, contact: contact, inbox: inbox, source_id: '42001')
      private_conv = create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: private_ci,
                                           additional_attributes: { 'chat_type' => 'private' })

      group_contact = create(:contact, account: account)
      group_ci = create(:contact_inbox, contact: group_contact, inbox: inbox, source_id: '-100999888')
      group_conv = create(:conversation, account: account, inbox: inbox, contact: group_contact, contact_inbox: group_ci,
                                         additional_attributes: { 'chat_type' => 'supergroup' })

      private_payload = CommunicationThreads::ChannelCapabilitiesBuilder.new(
        links: [private_conv.communication_thread_conversation]
      ).perform.first
      group_payload = CommunicationThreads::ChannelCapabilitiesBuilder.new(
        links: [group_conv.communication_thread_conversation]
      ).perform.first

      expect(private_payload).to include(
        channel: 'Channel::TelegramPersonal',
        can_call: true,
        media_server_enabled: true
      )
      expect(group_payload).to include(
        channel: 'Channel::TelegramPersonal',
        can_call: false
      )
    end
  end
end
