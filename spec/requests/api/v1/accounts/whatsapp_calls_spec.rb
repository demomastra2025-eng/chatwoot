require 'rails_helper'

RSpec.describe 'WhatsApp Calls API', type: :request do
  let(:account) { create(:account) }
  let(:administrator) { create(:user, account: account, role: :administrator) }
  let(:headers) { administrator.create_new_auth_token }
  let(:call) { create(:call, account: account, status: 'in_progress', media_session_id: 'session-1') }
  let(:media_client) { instance_double(Whatsapp::MediaServerClient) }
  let(:path) { "/api/v1/accounts/#{account.id}/whatsapp_calls/#{call.id}/play_audio" }

  before do
    Current.suppress_runtime_events = true
    Conversation.skip_callback(:create, :before, :determine_conversation_status)
    Conversation.skip_callback(:commit, :after, :notify_conversation_creation)
    account.enable_features!('whatsapp_call')
    allow(Whatsapp::MediaServerClient).to receive(:new).and_return(media_client)
  end

  after do
    Conversation.set_callback(:commit, :after, :notify_conversation_creation, on: :create)
    Conversation.set_callback(:create, :before, :determine_conversation_status)
    Current.suppress_runtime_events = nil
  end

  describe 'POST /play_audio' do
    it 'rejects traversal audio paths before calling the media server' do
      expect(media_client).not_to receive(:inject_audio)

      post path,
           params: { file_path: '../secret.ogg' },
           headers: headers,
           as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body['error']).to eq('Invalid file_path')
    end

    it 'passes only normalized relative ogg assets to the media server' do
      Dir.mktmpdir do |audio_root|
        FileUtils.mkdir_p(File.join(audio_root, 'prompts'))
        File.binwrite(File.join(audio_root, 'prompts', 'welcome.ogg'), 'ogg')

        expect(media_client).to receive(:inject_audio).with(
          'session-1',
          file_path: 'prompts/welcome.ogg',
          mode: 'mix',
          loop: true
        ).and_return({ 'id' => 'inj-1' })

        with_modified_env MEDIA_SERVER_AUDIO_ASSETS_ROOT: audio_root do
          post path,
               params: { file_path: 'prompts/../prompts/welcome.ogg', mode: 'mix', loop: true },
               headers: headers,
               as: :json
        end

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body['injection_id']).to eq('inj-1')
      end
    end
  end

  describe 'core call endpoints' do
    let(:provider_service) { double('provider_service') }

    before do
      allow_any_instance_of(Channel::Whatsapp).to receive(:provider_service).and_return(provider_service)
      call.inbox.channel.update!(
        provider: 'whatsapp_cloud',
        provider_config: call.inbox.channel.provider_config.merge(
          'source' => 'embedded_signup',
          'calling_enabled' => true,
          'media_server_enabled' => false
        )
      )
    end

    it 'returns the call payload from show' do
      get "/api/v1/accounts/#{account.id}/whatsapp_calls/#{call.id}",
          headers: headers,
          as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include(
        'id' => call.id,
        'call_id' => call.provider_call_id,
        'status' => 'in_progress',
        'media_server_enabled' => false
      )
    end

    it 'returns prepared agent offer for ringing media-server calls' do
      ringing_call = create(:call, account: account, status: 'ringing', media_session_id: 'media-early',
                                   meta: {
                                     'sdp_offer' => 'meta-offer',
                                     'agent_offer' => { 'sdp_offer' => 'agent-offer', 'ice_servers' => [] }
                                   })
      ringing_call.inbox.channel.update!(provider_config: ringing_call.inbox.channel.provider_config.merge('media_server_enabled' => true))

      with_modified_env(MEDIA_SERVER_URL: 'http://media-server:4000', MEDIA_SERVER_AUTH_TOKEN: 'secret') do
        get "/api/v1/accounts/#{account.id}/whatsapp_calls/#{ringing_call.id}",
            headers: headers,
            as: :json
      end

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include(
        'id' => ringing_call.id,
        'media_server_enabled' => true,
        'media_session_id' => 'media-early',
        'agent_offer' => {
          'sdp_offer' => 'agent-offer',
          'ice_servers' => []
        }
      )
    end

    it 'accepts direct mode only when sdp_answer is present' do
      ringing_call = create(:call, account: account, status: 'ringing', media_session_id: nil, meta: { 'sdp_offer' => 'v=0' })
      ringing_call.inbox.channel.update!(provider_config: ringing_call.inbox.channel.provider_config.merge('media_server_enabled' => false))
      allow(provider_service).to receive(:pre_accept_call).with(ringing_call.provider_call_id, 'answer').and_return(true)
      allow(provider_service).to receive(:accept_call).with(ringing_call.provider_call_id, 'answer').and_return(true)
      allow(ActionCable.server).to receive(:broadcast)

      post "/api/v1/accounts/#{account.id}/whatsapp_calls/#{ringing_call.id}/accept",
           params: { sdp_answer: 'answer' },
           headers: headers,
           as: :json

      expect(response).to have_http_status(:ok)
      expect(ringing_call.reload.status).to eq('in_progress')
    end

    it 'rejects direct accept without sdp_answer' do
      ringing_call = create(:call, account: account, status: 'ringing', media_session_id: nil, meta: { 'sdp_offer' => 'v=0' })
      ringing_call.inbox.channel.update!(provider_config: ringing_call.inbox.channel.provider_config.merge('media_server_enabled' => false))

      post "/api/v1/accounts/#{account.id}/whatsapp_calls/#{ringing_call.id}/accept",
           headers: headers,
           as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body['error']).to eq('sdp_answer is required')
    end

    it 'accepts media-server mode without browser SDP answer and returns agent offer for race-free browser handshake' do
      ringing_call = create(:call, account: account, status: 'ringing', accepted_by_agent_id: nil, media_session_id: nil,
                                   meta: { 'sdp_offer' => 'meta-offer', 'ice_servers' => [] })
      allow(media_client).to receive(:create_session).and_return({ 'session_id' => 'media-2', 'meta_sdp_answer' => 'meta-answer' })
      allow(media_client).to receive(:generate_agent_offer).with('media-2').and_return({ 'sdp_offer' => 'agent-offer', 'ice_servers' => [] })
      allow(provider_service).to receive(:pre_accept_call).with(ringing_call.provider_call_id, 'meta-answer').and_return(true)
      allow(provider_service).to receive(:accept_call).with(ringing_call.provider_call_id, 'meta-answer').and_return(true)
      allow(ActionCable.server).to receive(:broadcast)

      with_modified_env(MEDIA_SERVER_URL: 'http://media-server:4000', MEDIA_SERVER_AUTH_TOKEN: 'secret') do
        post "/api/v1/accounts/#{account.id}/whatsapp_calls/#{ringing_call.id}/accept",
             headers: headers,
             as: :json
      end

      expect(response).to have_http_status(:ok)
      expect(ringing_call.reload).to have_attributes(status: 'in_progress', media_session_id: 'media-2')
      expect(response.parsed_body).to include(
        'media_session_id' => 'media-2',
        'conversation_id' => ringing_call.conversation_id,
        'conversation_display_id' => ringing_call.conversation.display_id,
        'agent_offer' => {
          'sdp_offer' => 'agent-offer',
          'ice_servers' => []
        }
      )
    end

    it 'returns a controlled conflict when media leg closes before agent offer during accept' do
      ringing_call = create(:call, account: account, status: 'ringing', accepted_by_agent_id: nil, media_session_id: nil,
                                   meta: { 'sdp_offer' => 'meta-offer', 'ice_servers' => [] })
      error = Whatsapp::MediaServerClient::SessionError.new(
        'Media server error (409): media leg closed',
        http_status: 409,
        error_code: 'media_leg_closed'
      )
      allow(media_client).to receive(:create_session).and_return({ 'session_id' => 'media-closed', 'meta_sdp_answer' => 'meta-answer' })
      allow(media_client).to receive(:generate_agent_offer).with('media-closed').and_raise(error)
      allow(media_client).to receive(:terminate_session).with('media-closed')
      allow(provider_service).to receive(:pre_accept_call).with(ringing_call.provider_call_id, 'meta-answer').and_return(true)
      allow(provider_service).to receive(:accept_call).with(ringing_call.provider_call_id, 'meta-answer').and_return(true)
      allow(provider_service).to receive(:terminate_call).with(ringing_call.provider_call_id).and_return(true)

      with_modified_env(MEDIA_SERVER_URL: 'http://media-server:4000', MEDIA_SERVER_AUTH_TOKEN: 'secret') do
        post "/api/v1/accounts/#{account.id}/whatsapp_calls/#{ringing_call.id}/accept",
             headers: headers,
             as: :json
      end

      expect(response).to have_http_status(:conflict)
      expect(response.parsed_body).to include(
        'error' => 'media_leg_closed',
        'code' => 'media_leg_closed',
        'status' => 'media_leg_closed'
      )
      expect(ringing_call.reload).to have_attributes(status: 'ringing', media_session_id: nil, accepted_by_agent_id: nil)
    end

    it 'rejects a ringing call' do
      ringing_call = create(:call, account: account, status: 'ringing')
      allow(provider_service).to receive(:reject_call).with(ringing_call.provider_call_id).and_return(true)
      allow(ActionCable.server).to receive(:broadcast)

      post "/api/v1/accounts/#{account.id}/whatsapp_calls/#{ringing_call.id}/reject",
           headers: headers,
           as: :json

      expect(response).to have_http_status(:ok)
      expect(ringing_call.reload.status).to eq('failed')
    end

    it 'logs sanitized client timing for agent answer without SDP payloads' do
      allow(media_client).to receive(:set_agent_answer).with('session-1', sdp_answer: 'v=0')
      allow(Rails.logger).to receive(:info)

      post "/api/v1/accounts/#{account.id}/whatsapp_calls/#{call.id}/agent_answer",
           params: {
             sdp_answer: 'v=0',
             client_timing: {
               direction: 'outbound',
               context: 'outbound-connected',
               stages: {
                 offer_received_ms: 0,
                 agent_answer_post_start_ms: 4200
               },
               sdp_answer: 'SHOULD_NOT_BE_LOGGED'
             }
           },
           headers: headers,
           as: :json

      expect(response).to have_http_status(:ok)
      timing_log_pattern = /\[WHATSAPP CALL\] agent_answer client_timing call_id=#{call.id} .*/
      expect(Rails.logger).to have_received(:info).with(
        a_string_matching(timing_log_pattern)
          .and(a_string_matching(/direction=outbound/))
          .and(a_string_matching(/context=outbound-connected/))
          .and(a_string_matching(/agent_answer_post_start_ms=4200/))
      ).at_least(:once)
      expect(Rails.logger).not_to have_received(:info).with(a_string_including('SHOULD_NOT_BE_LOGGED'))
    end

    it 'accepts agent answer only for the current user prepared peer before the call is claimed' do
      ringing_call = create(:call, account: account, status: 'ringing', accepted_by_agent_id: nil, media_session_id: 'session-prepared',
                                   meta: {
                                     'agent_offers' => {
                                       administrator.id.to_s => { 'peer_id' => 'peer-admin', 'sdp_offer' => 'offer-admin', 'ice_servers' => [] }
                                     }
                                   })
      allow(media_client).to receive(:set_agent_answer).with('session-prepared', sdp_answer: 'v=0', peer_id: 'peer-admin')

      post "/api/v1/accounts/#{account.id}/whatsapp_calls/#{ringing_call.id}/agent_answer",
           params: { sdp_answer: 'v=0', peer_id: 'peer-admin' },
           headers: headers,
           as: :json

      expect(response).to have_http_status(:ok)
    end

    it 'rejects agent answer for another prepared peer' do
      ringing_call = create(:call, account: account, status: 'ringing', accepted_by_agent_id: nil, media_session_id: 'session-prepared',
                                   meta: {
                                     'agent_offers' => {
                                       administrator.id.to_s => { 'peer_id' => 'peer-admin', 'sdp_offer' => 'offer-admin', 'ice_servers' => [] }
                                     }
                                   })
      expect(media_client).not_to receive(:set_agent_answer)

      post "/api/v1/accounts/#{account.id}/whatsapp_calls/#{ringing_call.id}/agent_answer",
           params: { sdp_answer: 'v=0', peer_id: 'peer-other' },
           headers: headers,
           as: :json

      expect(response).to have_http_status(:forbidden)
    end

    it 'returns a controlled conflict when agent answer arrives after media leg closed' do
      error = Whatsapp::MediaServerClient::SessionError.new(
        'Media server error (409): media leg closed',
        http_status: 409,
        error_code: 'media_leg_closed'
      )
      allow(media_client).to receive(:set_agent_answer).with('session-1', sdp_answer: 'v=0').and_raise(error)

      post "/api/v1/accounts/#{account.id}/whatsapp_calls/#{call.id}/agent_answer",
           params: { sdp_answer: 'v=0' },
           headers: headers,
           as: :json

      expect(response).to have_http_status(:conflict)
      expect(response.parsed_body).to include(
        'error' => 'media_leg_closed',
        'code' => 'media_leg_closed',
        'status' => 'media_leg_closed'
      )
    end

    it 'terminates an active call' do
      allow(media_client).to receive(:terminate_session).with('session-1')
      allow(provider_service).to receive(:terminate_call).with(call.provider_call_id).and_return(true)
      allow(ActionCable.server).to receive(:broadcast)

      post "/api/v1/accounts/#{account.id}/whatsapp_calls/#{call.id}/terminate",
           headers: headers,
           as: :json

      expect(response).to have_http_status(:ok)
      expect(call.reload.status).to eq('completed')
    end
  end

  describe 'POST /initiate' do
    let(:provider_service) { double('provider_service') }
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
    let(:contact) { create(:contact, :with_phone_number, account: account) }
    let(:conversation) { create(:conversation, account: account, inbox: channel.inbox, contact: contact) }
    let(:initiate_path) { "/api/v1/accounts/#{account.id}/whatsapp_calls/initiate" }

    before do
      allow_any_instance_of(Channel::Whatsapp).to receive(:provider_service).and_return(provider_service)
      allow(ActionCable.server).to receive(:broadcast)
    end

    it 'creates an outbound direct ringing call' do
      allow(provider_service).to receive(:initiate_call)
        .with(contact.phone_number.delete('+'), 'v=0')
        .and_return({ 'calls' => [{ 'id' => 'wacid.outbound-1' }] })

      post initiate_path,
           params: { conversation_id: conversation.display_id, sdp_offer: 'v=0' },
           headers: headers,
           as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include('status' => 'calling', 'call_id' => 'wacid.outbound-1')
      created_call = Call.find_by!(provider_call_id: 'wacid.outbound-1')
      expect(created_call).to have_attributes(direction: 'outgoing', status: 'ringing', accepted_by_agent_id: administrator.id)
      expect(created_call.meta['sdp_offer']).to eq('v=0')
      expect(created_call.message).to have_attributes(source_id: 'wacid.outbound-1', content_type: 'voice_call')
    end

    it 'creates an outbound media-server ringing call and returns an immediate agent offer' do
      channel.update!(provider_config: channel.provider_config.merge('media_server_enabled' => true))
      allow(media_client).to receive(:create_session).and_return({ 'session_id' => 'media-out-1', 'meta_sdp_offer' => 'meta-offer' })
      allow(media_client).to receive(:generate_agent_offer).with('media-out-1').and_return(
        { 'sdp_offer' => 'agent-offer', 'ice_servers' => [] }
      )
      allow(media_client).to receive(:set_meta_answer).with('media-out-1', sdp_answer: 'early-answer')
      allow(provider_service).to receive(:initiate_call)
        .with(contact.phone_number.delete('+'), 'meta-offer') do
          Whatsapp::IncomingCallService.new(
            inbox: channel.inbox,
            params: {
              calls: [
                {
                  id: 'wacid.outbound-media',
                  event: 'connect',
                  session: { sdp_type: 'answer', sdp: 'early-answer' }
                }
              ]
            }
          ).perform
          { 'calls' => [{ 'id' => 'wacid.outbound-media' }] }
        end

      with_modified_env(MEDIA_SERVER_URL: 'http://media-server:4000', MEDIA_SERVER_AUTH_TOKEN: 'secret') do
        post initiate_path,
             params: { conversation_id: conversation.display_id },
             headers: headers,
             as: :json
      end

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include(
        'media_session_id' => 'media-out-1',
        'agent_offer' => {
          'sdp_offer' => 'agent-offer',
          'ice_servers' => []
        }
      )
      created_call = Call.find_by!(provider_call_id: 'wacid.outbound-media')
      expect(created_call).to have_attributes(status: 'ringing', media_session_id: 'media-out-1')
      expect(created_call.message).to have_attributes(source_id: 'wacid.outbound-media', content_type: 'voice_call')
      expect(created_call.meta).to include('sdp_offer' => 'meta-offer', 'sdp_answer' => 'early-answer')
      expect(created_call.meta['agent_offer_generated_at']).to be_present
      expect(created_call.meta['meta_answer_set_at']).to be_present
    end

    it 'sends and stores a WhatsApp call permission request when Meta rejects outbound calling permission' do
      allow(provider_service).to receive(:initiate_call).and_raise(Whatsapp::CallErrors::NoCallPermission)
      allow(provider_service).to receive(:send_call_permission_request)
        .with(contact.phone_number.delete('+'))
        .and_return({ 'messages' => [{ 'id' => 'wamid.permission-1' }] })

      post initiate_path,
           params: { conversation_id: conversation.display_id, sdp_offer: 'v=0' },
           headers: headers,
           as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body['status']).to eq('permission_requested')
      expect(conversation.reload.additional_attributes).to include('call_permission_request_message_id' => 'wamid.permission-1')
    end

    it 'returns permission_pending for repeated permission requests within the throttle window' do
      conversation.update!(
        additional_attributes: {
          'call_permission_requested_at' => 1.minute.ago.iso8601,
          'call_permission_request_message_id' => 'wamid.permission-existing'
        }
      )
      allow(provider_service).to receive(:initiate_call).and_raise(Whatsapp::CallErrors::NoCallPermission)
      expect(provider_service).not_to receive(:send_call_permission_request)

      post initiate_path,
           params: { conversation_id: conversation.display_id, sdp_offer: 'v=0' },
           headers: headers,
           as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body['status']).to eq('permission_pending')
    end

    it 'returns 422 when sending the permission request fails at transport level' do
      allow(provider_service).to receive(:initiate_call).and_raise(Whatsapp::CallErrors::NoCallPermission)
      allow(provider_service).to receive(:send_call_permission_request).and_raise(HTTParty::Error)

      post initiate_path,
           params: { conversation_id: conversation.display_id, sdp_offer: 'v=0' },
           headers: headers,
           as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body['error']).to eq('Failed to send call permission request')
    end

    it 'returns 422 when the conversation contact has no phone number' do
      contact.update!(phone_number: nil)

      post initiate_path,
           params: { conversation_id: conversation.display_id, sdp_offer: 'v=0' },
           headers: headers,
           as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body['error']).to eq('Contact phone number not available')
    end

    it 'returns 422 for non-eligible inboxes' do
      channel.update!(provider_config: channel.provider_config.merge('source' => 'manual'))

      post initiate_path,
           params: { conversation_id: conversation.display_id, sdp_offer: 'v=0' },
           headers: headers,
           as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body['error']).to eq('Calling is not enabled for this inbox')
    end
  end
end
