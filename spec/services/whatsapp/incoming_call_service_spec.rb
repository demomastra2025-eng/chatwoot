require 'rails_helper'

RSpec.describe Whatsapp::IncomingCallService do
  let(:account) { create(:account) }
  let(:agent) { create(:user, account: account) }
  let(:channel) do
    create(
      :channel_whatsapp,
      account: account,
      provider: 'whatsapp_cloud',
      provider_config: { 'source' => 'embedded_signup', 'calling_enabled' => true, 'media_server_enabled' => false },
      validate_provider_config: false,
      sync_templates: false
    )
  end
  let(:inbox) { channel.inbox }
  let(:contact) { create(:contact, :with_phone_number, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, contact: contact) }

  before do
    Current.suppress_runtime_events = true
    Conversation.skip_callback(:create, :before, :determine_conversation_status)
    Conversation.skip_callback(:commit, :after, :notify_conversation_creation)
    account.enable_features!('whatsapp_call')
    allow(ActionCable.server).to receive(:broadcast)
    allow(Whatsapp::CallMessageBuilder).to receive(:update_status!)
  end

  after do
    Conversation.set_callback(:commit, :after, :notify_conversation_creation, on: :create)
    Conversation.set_callback(:create, :before, :determine_conversation_status)
    Current.suppress_runtime_events = nil
  end

  describe '#perform' do
    it 'creates an inbound ringing call from a connect offer' do
      message = instance_double(Message, id: 123)
      allow(Whatsapp::CallMessageBuilder).to receive(:create!).and_return(message)

      described_class.new(
        inbox: inbox,
        params: {
          calls: [
            {
              id: 'wa-inbound-1',
              from: '15551234567',
              event: 'connect',
              session: { sdp_type: 'offer', sdp: 'v=0' }
            }
          ]
        }
      ).perform

      call = Call.whatsapp.find_by!(provider_call_id: 'wa-inbound-1')
      expect(call).to be_incoming
      expect(call.status).to eq('ringing')
      expect(call.meta['sdp_offer']).to eq('v=0')
      expect(call.conversation.additional_attributes).to include('call_status' => 'ringing', 'call_direction' => 'inbound')
      expect(ActionCable.server).to have_received(:broadcast).with(
        "account_#{account.id}",
        hash_including(
          event: 'whatsapp_call.incoming',
          data: hash_including(call_id: 'wa-inbound-1', conversation_display_id: call.conversation.display_id)
        )
      )
    end

    it 'stores outbound SDP answer on connect without marking the call connected' do
      call = create(
        :call,
        account: account,
        inbox: inbox,
        contact: contact,
        conversation: conversation,
        direction: :outgoing,
        status: 'ringing',
        accepted_by_agent: agent,
        media_session_id: nil,
        meta: {}
      )

      described_class.new(
        inbox: inbox,
        params: {
          calls: [
            {
              id: call.provider_call_id,
              event: 'connect',
              session: { sdp_type: 'answer', sdp: "v=0\na=setup:actpass\n" }
            }
          ]
        }
      ).perform

      call.reload
      expect(call.status).to eq('ringing')
      expect(call.started_at).to be_nil
      expect(call.meta['sdp_answer']).to include('a=setup:active')
      expect(ActionCable.server).to have_received(:broadcast).with(
        "account_#{account.id}",
        hash_including(event: 'whatsapp_call.outbound_connected', data: hash_including(call_id: call.provider_call_id))
      )
    end

    it 'retries media-server outbound finalize until an agent offer is generated' do
      media_client = instance_double(Whatsapp::MediaServerClient)
      allow(Whatsapp::MediaServerClient).to receive(:new).and_return(media_client)
      allow(media_client).to receive(:set_meta_answer).with('media-out-1', sdp_answer: 'stored-answer')
      allow(media_client).to receive(:generate_agent_offer).with('media-out-1').and_return(
        { 'sdp_offer' => 'agent-offer', 'ice_servers' => [] }
      )
      call = create(
        :call,
        account: account,
        inbox: inbox,
        contact: contact,
        conversation: conversation,
        direction: :outgoing,
        status: 'ringing',
        media_session_id: 'media-out-1',
        meta: { 'sdp_answer' => 'stored-answer' }
      )

      described_class.new(
        inbox: inbox,
        params: {
          calls: [
            {
              id: call.provider_call_id,
              event: 'connect',
              session: { sdp_type: 'answer', sdp: 'stored-answer' }
            }
          ]
        }
      ).perform

      expect(media_client).to have_received(:set_meta_answer)
      expect(media_client).to have_received(:generate_agent_offer)
      expect(call.reload.meta['agent_offer_generated_at']).to be_present
      expect(ActionCable.server).to have_received(:broadcast).with(
        "account_#{account.id}",
        hash_including(event: 'whatsapp_call.outbound_connected', data: hash_including(sdp_offer: 'agent-offer'))
      )
    end

    it 'marks an outbound call in progress only after Meta sends ACCEPTED status' do
      timestamp = 1_776_000_000
      call = create(
        :call,
        account: account,
        inbox: inbox,
        contact: contact,
        conversation: conversation,
        direction: :outgoing,
        status: 'ringing',
        accepted_by_agent: agent,
        media_session_id: nil
      )

      described_class.new(
        inbox: inbox,
        params: {
          statuses: [
            { id: call.provider_call_id, type: 'call', status: 'ACCEPTED', timestamp: timestamp }
          ]
        }
      ).perform

      call.reload
      expect(call.status).to eq('in_progress')
      expect(call.started_at.to_i).to eq(timestamp)
      expect(call.conversation.additional_attributes).to include('call_status' => 'in-progress', 'call_direction' => 'outbound')
      expect(Whatsapp::CallMessageBuilder).to have_received(:update_status!).with(
        call: call,
        status: 'in_progress',
        agent: agent
      )
      expect(ActionCable.server).to have_received(:broadcast).with(
        "account_#{account.id}",
        hash_including(event: 'whatsapp_call.outbound_accepted', data: hash_including(call_id: call.provider_call_id))
      )
    end

    it 'ends an unanswered outbound ringing call as no_answer even when it has an initiating agent' do
      call = create(
        :call,
        account: account,
        inbox: inbox,
        contact: contact,
        conversation: conversation,
        direction: :outgoing,
        status: 'ringing',
        accepted_by_agent: agent,
        media_session_id: nil
      )

      described_class.new(
        inbox: inbox,
        params: {
          calls: [
            { id: call.provider_call_id, event: 'terminate', duration: 0, terminate_reason: 'completed' }
          ]
        }
      ).perform

      expect(call.reload.status).to eq('no_answer')
      expect(Whatsapp::CallMessageBuilder).to have_received(:update_status!).with(
        call: call,
        status: 'no_answer',
        agent: agent,
        duration_seconds: 0
      )
    end

    it 'is a no-op when WhatsApp calling is disabled for the channel' do
      channel.update!(provider_config: channel.provider_config.merge('calling_enabled' => false))

      expect do
        described_class.new(
          inbox: inbox,
          params: {
            calls: [
              {
                id: 'wa-disabled-1',
                from: '15551234567',
                event: 'connect',
                session: { sdp_type: 'offer', sdp: 'v=0' }
              }
            ]
          }
        ).perform
      end.not_to change(Call, :count)
    end

    it 'does not create an inbound call for an unknown outbound answer payload' do
      allow(Rails.logger).to receive(:warn)

      expect do
        described_class.new(
          inbox: inbox,
          params: {
            calls: [
              {
                id: 'wa-unknown-answer',
                event: 'connect',
                session: { sdp_type: 'answer', sdp: 'v=0' }
              }
            ]
          }
        ).perform
      end.not_to change(Call, :count)

      expect(Rails.logger).to have_received(:warn).with(/Outbound connect for unknown call/)
    end

    it 'logs and skips terminate for an unknown local row' do
      allow(Rails.logger).to receive(:warn)

      expect do
        described_class.new(
          inbox: inbox,
          params: { calls: [{ id: 'wa-missing', event: 'terminate', duration: 0, terminate_reason: 'no_answer' }] }
        ).perform
      end.not_to change(Call, :count)

      expect(Rails.logger).to have_received(:warn).with(/Terminate for unknown call/)
      expect(ActionCable.server).not_to have_received(:broadcast)
    end

    it 'does not alter terminal calls when Meta retries terminate' do
      call = create(
        :call,
        account: account,
        inbox: inbox,
        contact: contact,
        conversation: conversation,
        direction: :outgoing,
        status: 'completed',
        duration_seconds: 5,
        media_session_id: nil
      )

      described_class.new(
        inbox: inbox,
        params: { calls: [{ id: call.provider_call_id, event: 'terminate', duration: 0, terminate_reason: 'no_answer' }] }
      ).perform

      expect(call.reload).to have_attributes(status: 'completed', duration_seconds: 5)
    end

    it 'records failed terminate reasons as failed even when the call was in progress' do
      call = create(
        :call,
        account: account,
        inbox: inbox,
        contact: contact,
        conversation: conversation,
        direction: :incoming,
        status: 'in_progress',
        media_session_id: nil
      )

      described_class.new(
        inbox: inbox,
        params: { calls: [{ id: call.provider_call_id, event: 'terminate', duration: 12, terminate_reason: 'failed' }] }
      ).perform

      expect(call.reload).to have_attributes(status: 'failed', duration_seconds: 12, end_reason: 'failed')
    end

    it 'processes multiple inbound call payloads independently' do
      message = instance_double(Message, id: 123)
      allow(Whatsapp::CallMessageBuilder).to receive(:create!).and_return(message)

      expect do
        described_class.new(
          inbox: inbox,
          params: {
            calls: [
              { id: 'wa-inbound-a', from: '15551234567', event: 'connect', session: { sdp_type: 'offer', sdp: 'v=0-a' } },
              { id: 'wa-inbound-b', from: '15557654321', event: 'connect', session: { sdp_type: 'offer', sdp: 'v=0-b' } }
            ]
          }
        ).perform
      end.to change(Call, :count).by(2)

      expect(Call.where(provider_call_id: %w[wa-inbound-a wa-inbound-b]).pluck(:provider_call_id))
        .to contain_exactly('wa-inbound-a', 'wa-inbound-b')
    end

    it 'handles multiple status payloads independently and ignores non-call statuses' do
      accepted_call = create(
        :call,
        account: account,
        inbox: inbox,
        contact: contact,
        conversation: conversation,
        direction: :outgoing,
        status: 'ringing',
        media_session_id: nil
      )
      ignored_call = create(
        :call,
        account: account,
        inbox: inbox,
        contact: contact,
        conversation: conversation,
        direction: :outgoing,
        status: 'ringing',
        media_session_id: nil
      )

      described_class.new(
        inbox: inbox,
        params: {
          statuses: [
            { id: accepted_call.provider_call_id, type: 'call', status: 'ACCEPTED' },
            { id: ignored_call.provider_call_id, type: 'message', status: 'ACCEPTED' }
          ]
        }
      ).perform

      expect(accepted_call.reload.status).to eq('in_progress')
      expect(ignored_call.reload.status).to eq('ringing')
    end
  end
end
