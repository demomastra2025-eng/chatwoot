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
      account.enable_features!('communication_threads')
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
          data: hash_including(
            call_id: 'wa-inbound-1',
            conversation_display_id: call.conversation.display_id,
            communication_thread_id: call.conversation.communication_thread.display_id
          )
        )
      )
    end

    it 'uses the phone contact inbox for calls that include both phone and BSUID identities' do
      contact = create(:contact, account: account, phone_number: '+77475318623')
      phone_contact_inbox = create(:contact_inbox, contact: contact, inbox: inbox, source_id: '77475318623')
      bsuid_source_id = 'KZ.4378991855667096'
      allow(Whatsapp::CallMessageBuilder).to receive(:create!).and_return(instance_double(Message, id: 124))

      described_class.new(
        inbox: inbox,
        params: {
          contacts: [
            {
              wa_id: '77475318623',
              user_id: bsuid_source_id,
              profile: { name: 'Ahan' }
            }
          ],
          calls: [
            {
              id: 'wa-phone-bsuid-call-1',
              from: '77475318623',
              from_user_id: bsuid_source_id,
              event: 'connect',
              session: { sdp_type: 'offer', sdp: 'v=0' }
            }
          ]
        }
      ).perform

      call = Call.whatsapp.find_by!(provider_call_id: 'wa-phone-bsuid-call-1')
      expect(call.conversation.contact_inbox_id).to eq(phone_contact_inbox.id)
      expect(inbox.contact_inboxes.find_by!(source_id: bsuid_source_id).contact_id).to eq(contact.id)
    end

    it 'prepares the media-server agent leg as soon as an inbound connect rings operators' do
      channel.update!(provider_config: channel.provider_config.merge('media_server_enabled' => true))
      message = instance_double(Message, id: 123)
      media_client = instance_double(Whatsapp::MediaServerClient)
      allow(Whatsapp::CallMessageBuilder).to receive(:create!).and_return(message)
      allow(Whatsapp::MediaServerClient).to receive(:new).and_return(media_client)
      allow(media_client).to receive(:create_session).and_return({ 'session_id' => 'media-in-1', 'meta_sdp_answer' => 'meta-answer' })
      allow(media_client).to receive(:add_peer).and_return(
        { 'peer_id' => 'peer-agent-1', 'sdp_offer' => 'agent-offer', 'ice_servers' => [] }
      )
      allow(Whatsapp::CallCleanupJob).to receive_message_chain(:set, :perform_later)
      allow_any_instance_of(Inbox).to receive(:available_agents).and_return([instance_double(InboxMember, user: agent)])

      with_modified_env(MEDIA_SERVER_URL: 'http://media-server:4000', MEDIA_SERVER_AUTH_TOKEN: 'secret') do
        described_class.new(
          inbox: inbox,
          params: { calls: [{ id: 'wa-early-inbound-1', from: '15551234567', event: 'connect', session: { sdp_type: 'offer', sdp: 'v=0' } }] }
        ).perform
      end

      call = Call.whatsapp.find_by!(provider_call_id: 'wa-early-inbound-1')
      expect(media_client).to have_received(:create_session).with(
        call_id: 'wa-early-inbound-1',
        direction: 'incoming',
        sdp_offer: 'v=0',
        ice_servers: [{ 'urls' => ['stun:stun.l.google.com:19302'] }],
        account_id: account.id
      )
      expect(media_client).to have_received(:add_peer).with('media-in-1', role: 'listen_only', label: agent.name)
      expect(call.media_session_id).to eq('media-in-1')
      expect(call.meta).to include(
        'media_sdp_answer' => 'meta-answer',
        'agent_offers' => hash_including(
          agent.id.to_s => hash_including('peer_id' => 'peer-agent-1', 'sdp_offer' => 'agent-offer', 'ice_servers' => [])
        ),
        'agent_offer_generated_at' => be_present
      )
      expect(ActionCable.server).to have_received(:broadcast).with(
        "account_#{account.id}",
        hash_including(
          event: 'whatsapp_call.incoming',
          data: hash_including(
            call_id: 'wa-early-inbound-1',
            media_server_enabled: true,
            media_session_id: 'media-in-1',
            agent_offers: hash_including(
              agent.id.to_s => hash_including('peer_id' => 'peer-agent-1', 'sdp_offer' => 'agent-offer', 'ice_servers' => [])
            )
          )
        )
      )
    end

    it 'keeps a shared early agent offer when no online inbox agents are resolvable' do
      channel.update!(provider_config: channel.provider_config.merge('media_server_enabled' => true))
      message = instance_double(Message, id: 123)
      media_client = instance_double(Whatsapp::MediaServerClient)
      allow(Whatsapp::CallMessageBuilder).to receive(:create!).and_return(message)
      allow(Whatsapp::MediaServerClient).to receive(:new).and_return(media_client)
      allow(media_client).to receive(:create_session).and_return({ 'session_id' => 'media-in-empty', 'meta_sdp_answer' => 'meta-answer' })
      allow(media_client).to receive(:generate_agent_offer).and_return(
        { 'peer_id' => 'peer-shared-1', 'sdp_offer' => 'shared-agent-offer', 'ice_servers' => [] }
      )
      allow(Whatsapp::CallCleanupJob).to receive_message_chain(:set, :perform_later)
      allow_any_instance_of(Inbox).to receive(:available_agents).and_return([])

      with_modified_env(MEDIA_SERVER_URL: 'http://media-server:4000', MEDIA_SERVER_AUTH_TOKEN: 'secret') do
        described_class.new(
          inbox: inbox,
          params: { calls: [{ id: 'wa-shared-fallback-1', from: '15551234567', event: 'connect', session: { sdp_type: 'offer', sdp: 'v=0' } }] }
        ).perform
      end

      call = Call.whatsapp.find_by!(provider_call_id: 'wa-shared-fallback-1')
      expect(media_client).to have_received(:generate_agent_offer).with('media-in-empty')
      expect(call.meta).to include(
        'media_sdp_answer' => 'meta-answer',
        'agent_offer' => hash_including('peer_id' => 'peer-shared-1', 'sdp_offer' => 'shared-agent-offer', 'ice_servers' => []),
        'agent_offers' => {},
        'agent_offer_generated_at' => be_present
      )
      expect(ActionCable.server).to have_received(:broadcast).with(
        "account_#{account.id}",
        hash_including(
          event: 'whatsapp_call.incoming',
          data: hash_including(
            call_id: 'wa-shared-fallback-1',
            media_server_enabled: true,
            media_session_id: 'media-in-empty',
            agent_offer: hash_including('peer_id' => 'peer-shared-1', 'sdp_offer' => 'shared-agent-offer', 'ice_servers' => [])
          )
        )
      )
    end

    it 'routes an inbound call for an open conversation to the operator UI' do
      create(:captain_inbox, inbox: inbox, captain_assistant: create(:captain_assistant, account: account))
      contact_inbox = create(:contact_inbox, contact: contact, inbox: inbox, source_id: '15551234567')
      conversation.update!(contact_inbox: contact_inbox, status: 'open')
      allow(Whatsapp::CallMessageBuilder).to receive(:create!).and_return(instance_double(Message, id: 124))

      described_class.new(
        inbox: inbox,
        params: {
          calls: [
            {
              id: 'wa-open-route-1',
              from: '15551234567',
              event: 'connect',
              session: { sdp_type: 'offer', sdp: 'v=0' }
            }
          ]
        }
      ).perform

      call = Call.whatsapp.find_by!(provider_call_id: 'wa-open-route-1')
      expect(call.meta.dig('routing', 'action')).to eq('human_ring')
      expect(call.meta.dig('routing', 'reason')).to eq('conversation_open_operator_owns_call')
      expect(ActionCable.server).to have_received(:broadcast).with(
        "account_#{account.id}",
        hash_including(event: 'whatsapp_call.incoming', data: hash_including(call_id: 'wa-open-route-1'))
      )
    end

    it 'routes an inbound call for a pending conversation to the AI voice agent instead of ringing operators' do
      channel.update!(provider_config: channel.provider_config.merge('ai_voice_enabled' => true))
      create(:captain_inbox, inbox: inbox, captain_assistant: create(:captain_assistant, account: account))
      contact_inbox = create(:contact_inbox, contact: contact, inbox: inbox, source_id: '15551234567')
      conversation.update!(contact_inbox: contact_inbox, status: 'pending')
      ai_voice_service = instance_double(Whatsapp::AiVoiceCallService, perform: true)
      allow(Whatsapp::CallMessageBuilder).to receive(:create!).and_return(instance_double(Message, id: 125))
      expect(Whatsapp::AiVoiceCallService).to receive(:new).with(
        call: instance_of(Call),
        routing_decision: satisfy(&:ai?)
      ).and_return(ai_voice_service)

      described_class.new(
        inbox: inbox,
        params: {
          calls: [
            {
              id: 'wa-pending-route-1',
              from: '15551234567',
              event: 'connect',
              session: { sdp_type: 'offer', sdp: 'v=0' }
            }
          ]
        }
      ).perform

      call = Call.whatsapp.find_by!(provider_call_id: 'wa-pending-route-1')
      expect(call.meta.dig('routing', 'action')).to eq('ai_accept')
      expect(call.meta.dig('routing', 'reason')).to eq('conversation_pending_ai_voice_enabled')
      expect(call.conversation.additional_attributes).to include('call_status' => 'ai_accepting', 'call_direction' => 'inbound')
      expect(ActionCable.server).not_to have_received(:broadcast).with(
        "account_#{account.id}",
        hash_including(event: 'whatsapp_call.incoming')
      )
      expect(ActionCable.server).to have_received(:broadcast).with(
        "account_#{account.id}",
        hash_including(event: 'whatsapp_call.ai_accepting', data: hash_including(call_id: 'wa-pending-route-1'))
      )
    end

    it 'falls back to the operator UI when AI voice auto-answer fails' do
      channel.update!(provider_config: channel.provider_config.merge('ai_voice_enabled' => true))
      create(:captain_inbox, inbox: inbox, captain_assistant: create(:captain_assistant, account: account))
      contact_inbox = create(:contact_inbox, contact: contact, inbox: inbox, source_id: '15551234567')
      conversation.update!(contact_inbox: contact_inbox, status: 'pending')
      ai_voice_service = instance_double(Whatsapp::AiVoiceCallService)
      allow(Whatsapp::CallMessageBuilder).to receive(:create!).and_return(instance_double(Message, id: 126))
      allow(Whatsapp::AiVoiceCallService).to receive(:new).and_return(ai_voice_service)
      allow(ai_voice_service).to receive(:perform).and_raise(Whatsapp::CallErrors::NotRinging, 'Media server is not enabled')

      expect do
        described_class.new(
          inbox: inbox,
          params: {
            calls: [
              {
                id: 'wa-ai-fallback-1',
                from: '15551234567',
                event: 'connect',
                session: { sdp_type: 'offer', sdp: 'v=0' }
              }
            ]
          }
        ).perform
      end.not_to raise_error

      call = Call.whatsapp.find_by!(provider_call_id: 'wa-ai-fallback-1')
      expect(call.status).to eq('ringing')
      expect(call.meta.dig('ai_voice', 'state')).to eq('failed')
      expect(call.meta.dig('ai_voice', 'fallback')).to eq('human_ring')
      expect(call.conversation.additional_attributes).to include('call_status' => 'ringing', 'call_direction' => 'inbound')
      expect(ActionCable.server).to have_received(:broadcast).with(
        "account_#{account.id}",
        hash_including(event: 'whatsapp_call.incoming', data: hash_including(call_id: 'wa-ai-fallback-1'))
      )
    end

    it 'does not ring operators when AI voice failed after Meta was already accepted and closed' do
      channel.update!(provider_config: channel.provider_config.merge('ai_voice_enabled' => true))
      create(:captain_inbox, inbox: inbox, captain_assistant: create(:captain_assistant, account: account))
      contact_inbox = create(:contact_inbox, contact: contact, inbox: inbox, source_id: '15551234567')
      conversation.update!(contact_inbox: contact_inbox, status: 'pending')
      allow(Whatsapp::CallMessageBuilder).to receive(:create!).and_return(instance_double(Message, id: 127))
      allow(Whatsapp::AiVoiceCallService).to receive(:new) do |call:, **_kwargs|
        instance_double(Whatsapp::AiVoiceCallService).tap do |service|
          allow(service).to receive(:perform) do
            call.update!(status: 'failed', meta: (call.meta || {}).merge('ai_voice' => { 'state' => 'failed' }))
            raise Whatsapp::MediaServerClient::SessionError, 'runtime attach failed'
          end
        end
      end

      expect do
        described_class.new(
          inbox: inbox,
          params: {
            calls: [
              {
                id: 'wa-ai-terminal-fallback-1',
                from: '15551234567',
                event: 'connect',
                session: { sdp_type: 'offer', sdp: 'v=0' }
              }
            ]
          }
        ).perform
      end.not_to raise_error

      call = Call.whatsapp.find_by!(provider_call_id: 'wa-ai-terminal-fallback-1')
      expect(call.status).to eq('failed')
      expect(call.conversation.additional_attributes).to include('call_status' => 'ai_failed', 'call_direction' => 'inbound')
      expect(ActionCable.server).not_to have_received(:broadcast).with(
        "account_#{account.id}",
        hash_including(event: 'whatsapp_call.incoming', data: hash_including(call_id: 'wa-ai-terminal-fallback-1'))
      )
      expect(ActionCable.server).to have_received(:broadcast).with(
        "account_#{account.id}",
        hash_including(event: 'whatsapp_call.ended', data: hash_including(call_id: 'wa-ai-terminal-fallback-1', status: 'failed'))
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

    it 'sets Meta answer without regenerating an agent offer when outbound browser leg was pre-created' do
      media_client = instance_double(Whatsapp::MediaServerClient)
      allow(Whatsapp::MediaServerClient).to receive(:new).and_return(media_client)
      allow(media_client).to receive(:set_meta_answer).with('media-out-pre', sdp_answer: "stored-answer\na=setup:active\n")
      expect(media_client).not_to receive(:generate_agent_offer)
      call = create(
        :call,
        account: account,
        inbox: inbox,
        contact: contact,
        conversation: conversation,
        direction: :outgoing,
        status: 'ringing',
        media_session_id: 'media-out-pre',
        meta: { 'agent_offer_generated_at' => 1_776_000_000 }
      )

      described_class.new(
        inbox: inbox,
        params: {
          calls: [
            {
              id: call.provider_call_id,
              event: 'connect',
              session: { sdp_type: 'answer', sdp: "stored-answer\na=setup:actpass\n" }
            }
          ]
        }
      ).perform

      call.reload
      expect(call.meta['sdp_answer']).to include('a=setup:active')
      expect(call.meta['meta_answer_set_at']).to be_present
      expect(ActionCable.server).not_to have_received(:broadcast).with(
        "account_#{account.id}",
        hash_including(event: 'whatsapp_call.outbound_connected')
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
