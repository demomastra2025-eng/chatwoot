# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Telegram Personal Calls API', type: :request do
  let(:account) { create(:account) }
  let(:agent) { create(:user, account: account, role: :administrator) }
  let(:other_agent) { create(:user, account: account, role: :administrator) }
  let(:headers) { agent.create_new_auth_token }
  let(:other_headers) { other_agent.create_new_auth_token }
  let(:channel) { create(:channel_telegram_personal, account: account, connection_state: 'connected') }
  let(:inbox) { channel.inbox }
  let(:contact) { create(:contact, :with_phone_number, account: account) }
  let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: inbox, source_id: '554433') }
  let(:conversation) do
    create(
      :conversation,
      account: account,
      inbox: inbox,
      contact: contact,
      contact_inbox: contact_inbox,
      additional_attributes: { 'chat_type' => 'private', 'peer_user_id' => '554433' }
    )
  end
  let(:gateway_client) { instance_double(TelegramPersonal::GatewayClient) }

  def janus_offer(peer_id)
    { transport: 'janus_audiobridge', room_id: 45_001, pin: 'room-pin', token: 'browser-token', peer_id: peer_id }
  end

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
    allow(TelegramPersonal::GatewayClient).to receive(:new).and_return(gateway_client)
  end

  after do
    Conversation.set_callback(:commit, :after, :notify_conversation_creation, on: :create)
    Conversation.set_callback(:create, :before, :determine_conversation_status)
    Current.suppress_runtime_events = nil
  end

  describe 'outbound Janus preconnect flow (prepare_outbound -> Janus join -> dial)' do
    it 'prepares an outbound call with agent_offer and voice_call message' do
      expect(gateway_client).to receive(:prepare_outbound_call!).with(
        hash_including(recipient_id: '554433')
      ).and_return(
        {
          session_id: 'tg-out-sess-1',
          agent_offer: janus_offer('peer-out-1')
        }
      )

      post "/api/v1/accounts/#{account.id}/telegram_personal_calls/prepare_outbound",
           params: { conversation_id: conversation.display_id },
           headers: headers,
           as: :json

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body).to include(
        'provider' => 'telegram_personal',
        'agent_offer' => a_hash_including(
          janus_offer('peer-out-1').stringify_keys.merge('server' => a_string_starting_with('wss://app.example.com/janus-sipuni?janus_ticket='))
        )
      )
      expect(body['agent_offer']).not_to have_key('sdp_offer')
      call = Call.telegram_personal.find(body['id'])
      expect(call.media_session_id).to eq('tg-out-sess-1')
      expect(call.message&.content_attributes&.dig('data')).to include(
        'provider' => 'telegram_personal', 'media_server_enabled' => true
      )
      expect(conversation.reload.additional_attributes['call_status']).to eq('ringing')
    end

    it 'transitions call, message, and conversation call_status to failed when dial fails' do
      call = Call.create!(
        provider: :telegram_personal, account: account, inbox: inbox, conversation: conversation,
        contact: contact, provider_call_id: 'pending_tg-out-fail-1', media_session_id: 'tg-out-fail-1',
        direction: :outgoing, status: 'ringing', accepted_by_agent: agent,
        meta: { 'outbound_prepare_pending' => true, 'agent_offer' => janus_offer('dial-fail-peer') }
      )
      msg = TelegramPersonal::CallMessageBuilder.create!(conversation: conversation, call: call, user: agent)
      call.update!(message_id: msg.id)
      conversation.update!(additional_attributes: conversation.additional_attributes.merge('call_status' => 'ringing'))

      dial_err = TelegramPersonal::GatewayClient::GatewayError.new('Peer privacy restricted', http_status: 422)
      allow(gateway_client).to receive(:dial_call!).and_raise(dial_err)
      allow(gateway_client).to receive(:terminate_call!).and_return({ ok: true })

      post "/api/v1/accounts/#{account.id}/telegram_personal_calls/#{call.id}/dial",
           headers: headers,
           as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(call.reload.status).to eq('failed')
      expect(msg.reload.content_attributes.dig('data', 'status')).to eq('failed')
      expect(conversation.reload.additional_attributes['call_status']).to eq('failed')
    end

    it 'dials Telegram on a prepared outbound Janus call' do
      call = Call.create!(
        provider: :telegram_personal, account: account, inbox: inbox, conversation: conversation,
        contact: contact, provider_call_id: 'pending_tg-out-sess-2', media_session_id: 'tg-out-sess-2',
        direction: :outgoing, status: 'ringing', accepted_by_agent: agent,
        meta: { 'outbound_prepare_pending' => true, 'agent_offer' => janus_offer('peer-out-2') }
      )
      msg = TelegramPersonal::CallMessageBuilder.create!(conversation: conversation, call: call, user: agent)
      call.update!(message_id: msg.id)

      expect(gateway_client).to receive(:dial_call!).with(
        call_ref: 'tg-out-sess-2'
      ).and_return({ call_id: 'tg-real-777', session_id: 'tg-out-sess-2', status: 'ringing' })

      post "/api/v1/accounts/#{account.id}/telegram_personal_calls/#{call.id}/dial",
           headers: headers,
           as: :json
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['call_id']).to eq('tg-real-777')
      expect(call.reload.provider_call_id).to eq('tg-real-777')
    end

    it 'rejects group conversations with 422' do
      conversation.update!(additional_attributes: { 'chat_type' => 'supergroup' })

      post "/api/v1/accounts/#{account.id}/telegram_personal_calls/prepare_outbound",
           params: { conversation_id: conversation.display_id },
           headers: headers,
           as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body['error']).to include('private')
    end

    it 'rejects the previous direct SDP endpoint without contacting the gateway' do
      call = Call.create!(
        provider: :telegram_personal,
        account: account,
        inbox: inbox,
        conversation: conversation,
        contact: contact,
        provider_call_id: 'pending_tg-closed',
        media_session_id: 'tg-closed',
        direction: :outgoing,
        status: 'ringing',
        accepted_by_agent: agent,
        meta: { 'outbound_prepare_pending' => true }
      )

      expect(TelegramPersonal::GatewayClient).not_to receive(:new)

      post "/api/v1/accounts/#{account.id}/telegram_personal_calls/#{call.id}/agent_answer",
           params: { sdp_answer: 'v=0\r\nanswer\r\n' },
           headers: headers,
           as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body['code']).to eq('janus_media_required')
    end

    it 'refuses legacy direct SDP and closes the prepared gateway session' do
      allow(gateway_client).to receive(:prepare_outbound_call!).and_return(
        session_id: 'legacy-outbound', agent_offer: { peer_id: 'old-peer', sdp_offer: 'v=0' }
      )
      expect(gateway_client).to receive(:terminate_call!).with(call_ref: 'legacy-outbound').and_return(ok: true)

      expect do
        post "/api/v1/accounts/#{account.id}/telegram_personal_calls/prepare_outbound",
             params: { conversation_id: conversation.display_id }, headers: headers, as: :json
      end.not_to change(Call.telegram_personal, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body['error']).to include('require Janus')
    end
  end

  describe 'inbound accept, reconnect, reject, terminate, active, show' do
    let!(:inbound_call) do
      Call.create!(
        provider: :telegram_personal,
        account: account,
        inbox: inbox,
        conversation: conversation,
        contact: contact,
        provider_call_id: 'tg-in-500',
        media_session_id: 'tg-sess-500',
        direction: :incoming,
        status: 'ringing'
      )
    end

    it 'blocks agent_answer before accept, accepts inbound call, and rejects a second agent' do
      post "/api/v1/accounts/#{account.id}/telegram_personal_calls/#{inbound_call.id}/agent_answer",
           params: { sdp_answer: 'v=0\r\nanswer\r\n' },
           headers: other_headers,
           as: :json
      expect(response).to have_http_status(:forbidden)

      expect(gateway_client).to receive(:accept_call!).with(call_ref: 'tg-sess-500').and_return(
        {
          session_id: 'tg-sess-500',
          agent_offer: janus_offer('peer-in-1')
        }
      )

      post "/api/v1/accounts/#{account.id}/telegram_personal_calls/#{inbound_call.id}/accept",
           headers: headers,
           as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['status']).to eq('in_progress')
      expect(response.parsed_body.dig('agent_offer', 'peer_id')).to eq('peer-in-1')

      post "/api/v1/accounts/#{account.id}/telegram_personal_calls/#{inbound_call.id}/accept",
           headers: other_headers,
           as: :json

      expect(response).to have_http_status(:unprocessable_entity)
    end

    it 'lists in_progress call in active and reconnects' do
      inbound_call.update!(status: 'in_progress', started_at: 10.seconds.ago, accepted_by_agent: agent)

      get "/api/v1/accounts/#{account.id}/telegram_personal_calls/active",
          headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['id']).to eq(inbound_call.id)

      expect(gateway_client).to receive(:reconnect_call!).with(call_ref: 'tg-sess-500').and_return(
        {
          agent_offer: janus_offer('peer-in-2')
        }
      )

      post "/api/v1/accounts/#{account.id}/telegram_personal_calls/#{inbound_call.id}/reconnect",
           headers: headers,
           as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['peer_id']).to eq('peer-in-2')
      expect(inbound_call.reload.meta.dig('agent_offer', 'peer_id')).to eq('peer-in-2')
      expect(response.parsed_body['server']).to include('janus_ticket=')
    end

    it 'rejects a concurrent reconnect without allocating another room or changing the current lease' do
      inbound_call.update!(status: 'in_progress', started_at: 10.seconds.ago, accepted_by_agent: agent)
      key = "telegram_personal:media_reconnect:#{account.id}:#{inbound_call.id}"
      lock = Redis::LockManager.new
      expect(lock.lock(key, 300)).to be_truthy
      expect(gateway_client).not_to receive(:reconnect_call!)

      begin
        post "/api/v1/accounts/#{account.id}/telegram_personal_calls/#{inbound_call.id}/reconnect", headers: headers, as: :json
        expect(response).to have_http_status(:conflict)
        expect(response.parsed_body['code']).to eq('CALL_RECONNECT_IN_PROGRESS')
        expect(lock.renew(key, 300)).to be(true)
      ensure
        lock.unlock(key)
      end
    end

    it 'serializes another worker before the gateway can create a second media generation' do
      inbound_call.update!(status: 'in_progress', started_at: 10.seconds.ago, accepted_by_agent: agent)
      expect(gateway_client).to receive(:reconnect_call!).once do
        expect do
          TelegramPersonal::ReconnectCallService.new(call: Call.find(inbound_call.id), agent: agent).perform
        end.to raise_error(Telephony::Error) { |error| expect(error.code).to eq('CALL_RECONNECT_IN_PROGRESS') }
        { agent_offer: janus_offer('current-worker-peer') }
      end

      post "/api/v1/accounts/#{account.id}/telegram_personal_calls/#{inbound_call.id}/reconnect", headers: headers, as: :json
      expect(response).to have_http_status(:ok)
      expect(inbound_call.reload.meta.dig('agent_offer', 'peer_id')).to eq('current-worker-peer')
    end

    it 'does not persist media after losing the distributed reconnect lease' do
      inbound_call.update!(status: 'in_progress', started_at: 10.seconds.ago, accepted_by_agent: agent,
                           meta: { agent_offer: janus_offer('previous-peer') })
      lock = Redis::LockManager.new
      allow(Redis::LockManager).to receive(:new).and_return(lock)
      allow(lock).to receive(:renew).and_return(false)
      expect(gateway_client).to receive(:reconnect_call!).and_return(agent_offer: janus_offer('stale-worker-peer'))
      expect(gateway_client).not_to receive(:terminate_call!)

      post "/api/v1/accounts/#{account.id}/telegram_personal_calls/#{inbound_call.id}/reconnect", headers: headers, as: :json
      expect(response).to have_http_status(:conflict)
      expect(inbound_call.reload.meta.dig('agent_offer', 'peer_id')).to eq('previous-peer')
    end

    it 'terminates an in_progress call' do
      inbound_call.update!(status: 'in_progress', started_at: 10.seconds.ago, accepted_by_agent: agent)
      expect(gateway_client).to receive(:terminate_call!).with(call_ref: 'tg-sess-500').and_return({ ok: true })

      post "/api/v1/accounts/#{account.id}/telegram_personal_calls/#{inbound_call.id}/terminate",
           headers: headers,
           as: :json

      expect(response).to have_http_status(:ok)
      expect(inbound_call.reload.status).to eq('completed')
    end

    it 'rejects a ringing inbound call and shows call metadata' do
      get "/api/v1/accounts/#{account.id}/telegram_personal_calls/#{inbound_call.id}",
          headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['call_id']).to eq('tg-in-500')

      expect(gateway_client).to receive(:reject_call!).with(call_ref: 'tg-sess-500').and_return({ ok: true })

      post "/api/v1/accounts/#{account.id}/telegram_personal_calls/#{inbound_call.id}/reject",
           headers: headers,
           as: :json

      expect(response).to have_http_status(:ok)
      expect(inbound_call.reload.status).to eq('failed')
      expect(inbound_call.end_reason).to eq('rejected')
    end

    it 'returns already accepted error when another agent accepts an already-taken in_progress call' do
      other_agent = create(:user, account: account, role: :agent)
      inbound_call.update!(status: 'in_progress', started_at: 2.seconds.ago, accepted_by_agent: other_agent)

      post "/api/v1/accounts/#{account.id}/telegram_personal_calls/#{inbound_call.id}/accept",
           headers: headers,
           as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body['error']).to include('already accepted')
    end

    it 'returns room credentials only to the accepted operator through show' do
      inbound_call.update!(status: 'in_progress', accepted_by_agent: agent, meta: { 'agent_offer' => janus_offer('owner-peer') })

      get "/api/v1/accounts/#{account.id}/telegram_personal_calls/#{inbound_call.id}", headers: other_headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['agent_offer']).to be_nil

      get "/api/v1/accounts/#{account.id}/telegram_personal_calls/#{inbound_call.id}", headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['agent_offer']).to include(janus_offer('owner-peer').stringify_keys)
    end

    it 'does not broadcast room credentials when an operator accepts' do
      events = []
      allow(ActionCable.server).to receive(:broadcast) { |_topic, payload| events << payload }
      allow(gateway_client).to receive(:accept_call!).and_return(session_id: 'tg-sess-500', agent_offer: janus_offer('accepted-peer'))

      post "/api/v1/accounts/#{account.id}/telegram_personal_calls/#{inbound_call.id}/accept", headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(ActionCable.server).to have_received(:broadcast).with(
        "account_#{account.id}",
        hash_including(event: 'telegram_personal_call.agent_offer', data: hash_including(media_ready: true))
      )
      expect(ActionCable.server).not_to have_received(:broadcast).with(
        anything,
        hash_including(event: 'telegram_personal_call.agent_offer', data: hash_including(token: anything))
      )
      expect(events.to_json).not_to include('room-pin', 'browser-token', 'janus_ticket')
    end

    it 'closes a legacy direct gateway leg and releases the incoming reservation' do
      allow(gateway_client).to receive(:accept_call!).and_return(session_id: 'tg-sess-500', agent_offer: { sdp_offer: 'v=0', peer_id: 'old-peer' })
      expect(gateway_client).to receive(:terminate_call!).with(call_ref: 'tg-sess-500').and_return(ok: true)

      post "/api/v1/accounts/#{account.id}/telegram_personal_calls/#{inbound_call.id}/accept", headers: headers, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body['code']).to eq('janus_media_required')
      expect(inbound_call.reload.accepted_by_agent_id).to be_nil
    end

    it 'revokes the previous room-generation ticket on reconnect' do
      inbound_call.update!(status: 'in_progress', accepted_by_agent: agent, meta: { 'agent_offer' => janus_offer('old-peer') })
      get "/api/v1/accounts/#{account.id}/telegram_personal_calls/#{inbound_call.id}", headers: headers
      uri = URI.parse(response.parsed_body.dig('agent_offer', 'server'))
      old_ticket = URI.decode_www_form(uri.query).to_h.fetch('janus_ticket')
      allow(gateway_client).to receive(:reconnect_call!).and_return(agent_offer: janus_offer('new-peer'))

      post "/api/v1/accounts/#{account.id}/telegram_personal_calls/#{inbound_call.id}/reconnect", headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(inbound_call.reload.meta.dig('agent_offer', 'peer_id')).to eq('new-peer')
      expect(Telephony::JanusWebsocketTicket.valid?(ticket: old_ticket, origin: 'https://app.example.com', path: '/janus-sipuni')).to be(false)
    end

    it 'returns media_leg_closed and clears operator busy state when reconnect finds a dead gateway call' do
      inbound_call.update!(status: 'in_progress', accepted_by_agent: agent, meta: { 'agent_offer' => janus_offer('old-peer') })
      allow(gateway_client).to receive(:reconnect_call!).and_raise(
        TelegramPersonal::GatewayClient::GatewayError.new('Call leg already closed', http_status: 409, code: 'media_leg_closed')
      )
      allow(gateway_client).to receive(:terminate_call!).and_return(ok: true)

      post "/api/v1/accounts/#{account.id}/telegram_personal_calls/#{inbound_call.id}/reconnect", headers: headers, as: :json

      expect(response).to have_http_status(:conflict)
      expect(response.parsed_body['code']).to eq('media_leg_closed')
      expect(inbound_call.reload).to be_terminal
      expect(Telephony::OperatorBusyService.new(account: account, user: agent).busy?).to be(false)
    end

    it 'does not resurrect a call that ends during a gateway reconnect' do
      inbound_call.update!(status: 'in_progress', accepted_by_agent: agent, meta: { 'agent_offer' => janus_offer('old-peer') })
      allow(gateway_client).to receive(:reconnect_call!) do
        inbound_call.update!(status: 'completed')
        { agent_offer: janus_offer('late-peer') }
      end
      expect(gateway_client).to receive(:terminate_call!).with(call_ref: 'tg-sess-500').and_return(ok: true)

      post "/api/v1/accounts/#{account.id}/telegram_personal_calls/#{inbound_call.id}/reconnect", headers: headers, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(inbound_call.reload.status).to eq('completed')
      expect(inbound_call.meta.dig('agent_offer', 'peer_id')).to eq('old-peer')
    end
  end
end
