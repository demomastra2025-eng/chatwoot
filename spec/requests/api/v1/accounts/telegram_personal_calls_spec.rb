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

  describe 'outbound preconnect flow (prepare_outbound -> agent_answer -> dial)' do
    it 'prepares an outbound call with agent_offer and voice_call message' do
      expect(gateway_client).to receive(:prepare_outbound_call!).with(
        hash_including(recipient_id: '554433')
      ).and_return(
        {
          session_id: 'tg-out-sess-1',
          agent_offer: {
            peer_id: 'peer-out-1',
            sdp_offer: 'v=0\r\no=- 1 1 IN IP4 127.0.0.1\r\n',
            ice_servers: [{ urls: ['stun:stun.l.google.com:19302'] }]
          }
        }
      )

      post "/api/v1/accounts/#{account.id}/telegram_personal_calls/prepare_outbound",
           params: { conversation_id: conversation.display_id },
           headers: headers,
           as: :json

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body['provider']).to eq('telegram_personal')
      expect(body.dig('agent_offer', 'sdp_offer')).to be_present
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
        meta: { 'outbound_prepare_pending' => true }
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

    it 'posts agent_answer and dials Telegram on a prepared outbound call' do
      call = Call.create!(
        provider: :telegram_personal, account: account, inbox: inbox, conversation: conversation,
        contact: contact, provider_call_id: 'pending_tg-out-sess-2', media_session_id: 'tg-out-sess-2',
        direction: :outgoing, status: 'ringing', accepted_by_agent: agent,
        meta: { 'outbound_prepare_pending' => true }
      )
      msg = TelegramPersonal::CallMessageBuilder.create!(conversation: conversation, call: call, user: agent)
      call.update!(message_id: msg.id)

      expect(gateway_client).to receive(:set_call_agent_answer!).with(
        call_ref: 'tg-out-sess-2', sdp_answer: 'v=0\r\nanswer\r\n', peer_id: 'peer-out-2'
      ).and_return({ ok: true })
      expect(gateway_client).to receive(:dial_call!).with(
        call_ref: 'tg-out-sess-2'
      ).and_return({ call_id: 'tg-real-777', session_id: 'tg-out-sess-2', status: 'ringing' })

      post "/api/v1/accounts/#{account.id}/telegram_personal_calls/#{call.id}/agent_answer",
           params: { sdp_answer: 'v=0\r\nanswer\r\n', peer_id: 'peer-out-2' },
           headers: headers,
           as: :json
      expect(response).to have_http_status(:ok)

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

    it 'returns 409 media_leg_closed when gateway reports closed media leg on agent_answer' do
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

      closed_err = TelegramPersonal::GatewayClient::GatewayError.new(
        'Call leg already closed',
        http_status: 409,
        code: 'media_leg_closed'
      )
      allow(gateway_client).to receive(:set_call_agent_answer!).and_raise(closed_err)
      allow(gateway_client).to receive(:terminate_call!).and_return({ ok: true })

      post "/api/v1/accounts/#{account.id}/telegram_personal_calls/#{call.id}/agent_answer",
           params: { sdp_answer: 'v=0\r\nanswer\r\n' },
           headers: headers,
           as: :json

      expect(response).to have_http_status(:conflict)
      expect(response.parsed_body['code']).to eq('media_leg_closed')
      expect(call.reload.status).to eq('failed')
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
          agent_offer: {
            peer_id: 'peer-in-1',
            sdp_offer: 'v=0\r\no=- 2 2 IN IP4 127.0.0.1\r\n',
            ice_servers: []
          }
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
          agent_offer: {
            peer_id: 'peer-in-2',
            sdp_offer: 'v=0\r\nreconnect\r\n',
            ice_servers: []
          }
        }
      )

      post "/api/v1/accounts/#{account.id}/telegram_personal_calls/#{inbound_call.id}/reconnect",
           headers: headers,
           as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['peer_id']).to eq('peer-in-2')
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
  end
end
