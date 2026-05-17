require 'rails_helper'

RSpec.describe 'Telephony Calls API', type: :request do
  let(:account) { create(:account) }
  let(:administrator) { create(:user, account: account, role: :administrator) }
  let(:headers) { administrator.create_new_auth_token }
  let(:voice_channel) { create(:channel_voice, :fonoster, account: account, phone_number: '+15551230000') }
  let(:voice_inbox) { voice_channel.inbox }
  let(:contact) { create(:contact, account: account, phone_number: '+15551239999', name: 'Voice Contact') }
  let(:path) { "/api/v1/accounts/#{account.id}/telephony/calls/outbound" }

  before do
    account.enable_features!('channel_voice')
  end

  it 'creates an outbound call through the telephony bridge and persists local call session' do
    voice_inbox.telephony_number_binding.routing_policy.update!(
      mode: 'ai',
      ai_app_ref: 'ai-app-ref'
    )

    with_modified_env(
      TELEPHONY_BRIDGE_BASE_URL: 'https://bridge.example',
      TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret'
    ) do
      stub_request(:post, 'https://bridge.example/telephony/calls/outbound')
        .with(headers: { 'X-Bridge-Secret' => 'bridge-secret', 'X-Account-Id' => account.id.to_s })
        .with do |request|
          body = JSON.parse(request.body)
          expect(body['from_number_ref']).to eq(voice_inbox.telephony_number_binding.number_ref)
          expect(body['to']).to eq(contact.phone_number)
          expect(body['app_ref']).to eq('ai-app-ref')
          expect(body['appRef']).to eq('ai-app-ref')
          expect(body['recording_enabled']).to be(true)
          expect(body.dig('metadata', 'chatwoot_inbox_id')).to eq(voice_inbox.id)
          expect(body.dig('metadata', 'recording_enabled')).to be(true)
          true
        end
        .to_return(
          status: 200,
          body: {
            call_ref: 'call-123',
            status: 'ringing'
          }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      post path,
           params: {
             inbox_id: voice_inbox.id,
             contact_id: contact.id
           },
           headers: headers,
           as: :json
    end

    expect(response).to have_http_status(:created)
    expect(response.parsed_body['call_sid']).to eq('call-123')

    call_session = account.telephony_call_sessions.find_by!(external_call_ref: 'call-123')
    expect(call_session.conversation).to be_present
    expect(call_session.contact_id).to eq(contact.id)
    expect(call_session.inbox_id).to eq(voice_inbox.id)
    expect(call_session.number_binding.number_ref).to eq(voice_inbox.telephony_number_binding.number_ref)
    expect(call_session.status).to eq('ringing')
    expect(call_session.direction).to eq('outbound')
    expect(call_session.conversation.identifier).to eq('call-123')
    expect(call_session.metadata['fonoster_call_ref']).to eq('call-123')
    expect(call_session.conversation.additional_attributes['fonoster_call_ref']).to eq('call-123')
  end

  it 'streams a stored OneLink runtime recording through an account-scoped route' do
    call_session = create_recorded_call_session('recording-call-1')
    recording_path = Rails.root.join('storage', call_session.metadata.dig('recording', 'storage_key'))
    FileUtils.mkdir_p(recording_path.dirname)
    File.binwrite(recording_path, "RIFF\x24\x00\x00\x00WAVEfmt ")

    get "/api/v1/accounts/#{account.id}/telephony/calls/#{call_session.external_call_ref}", headers: headers

    expect(response).to have_http_status(:ok)
    signed_recording_url = response.parsed_body.dig('payload', 'recording_url')
    expect(signed_recording_url).to start_with("/api/v1/accounts/#{account.id}/telephony/calls/#{call_session.external_call_ref}/recording?")
    expect(signed_recording_url).to include('recording_token=')

    get signed_recording_url

    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq('audio/wav')
    expect(response.body).to start_with('RIFF')

    get "/api/v1/accounts/#{account.id}/telephony/calls/#{call_session.external_call_ref}/recording", headers: headers

    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq('audio/wav')
    expect(response.body).to start_with('RIFF')
  ensure
    FileUtils.rm_f(recording_path) if defined?(recording_path) && recording_path.present?
  end

  it 'rejects an invalid signed recording playback URL without falling back to account auth' do
    call_session = create_recorded_call_session('invalid-token-recording-call')

    get "/api/v1/accounts/#{account.id}/telephony/calls/#{call_session.external_call_ref}/recording?recording_token=invalid"

    expect(response).to have_http_status(:not_found)
  end

  it 'rejects a signed recording token minted for another account call session' do
    call_session = create_recorded_call_session('target-token-recording-call')
    other_account = create(:account)
    other_account.enable_features!('channel_voice')
    other_call_session = create(
      :telephony_call_session,
      account: other_account,
      external_call_ref: 'other-token-recording-call',
      recording_ref: 'voice-recordings/999/other-token-recording-call/recording.wav',
      metadata: {
        'recording' => recording_metadata.merge('storage_key' => 'voice-recordings/999/other-token-recording-call/recording.wav')
      }
    )
    other_storage_key = other_call_session.metadata.dig('recording', 'storage_key')
    other_token = Telephony::CallRecordingPlaybackUrl.token_for(other_call_session, storage_key: other_storage_key)

    get "/api/v1/accounts/#{account.id}/telephony/calls/#{call_session.external_call_ref}/recording",
        params: { recording_token: other_token }

    expect(response).to have_http_status(:not_found)
  end

  it 'returns and redirects to an account-scoped external Fonoster recording URL' do
    external_url = 'https://cloud.vconsult.kz/api/recordings/operator-call.wav'
    call_session = create_recorded_call_session(
      'external-recording-call',
      recording_metadata.merge('storage_key' => nil, 'recording_ref' => external_url),
      recording_ref: external_url
    )

    get "/api/v1/accounts/#{account.id}/telephony/calls/#{call_session.external_call_ref}", headers: headers

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('payload', 'recording_url')).to eq(external_url)

    get "/api/v1/accounts/#{account.id}/telephony/calls/#{call_session.external_call_ref}/recording", headers: headers

    expect(response).to redirect_to(external_url)
  end

  it 'does not expose another account recording for the same call ref' do
    other_account = create(:account)
    create(:telephony_call_session, account: other_account, external_call_ref: 'other-recording-call', metadata: recording_metadata)

    get "/api/v1/accounts/#{account.id}/telephony/calls/other-recording-call/recording", headers: headers

    expect(response).to have_http_status(:not_found)
  end

  it 'rejects recording storage keys outside the OneLink recording root' do
    call_session = create(
      :telephony_call_session,
      account: account,
      external_call_ref: 'unsafe-recording-call',
      metadata: { 'recording' => recording_metadata.merge('storage_key' => '../secrets.wav') }
    )

    get "/api/v1/accounts/#{account.id}/telephony/calls/#{call_session.external_call_ref}/recording", headers: headers

    expect(response).to have_http_status(:not_found)
  end

  it 'rejects recording storage keys that resolve through symlinks outside storage' do
    call_session = create_recorded_call_session('symlink-recording-call')
    outside_path = Rails.root.join('tmp/recording-secret.wav')
    symlink_path = Rails.root.join('storage', call_session.metadata.dig('recording', 'storage_key'))
    FileUtils.mkdir_p(symlink_path.dirname)
    File.binwrite(outside_path, 'secret audio')
    FileUtils.ln_s(outside_path, symlink_path)

    get "/api/v1/accounts/#{account.id}/telephony/calls/#{call_session.external_call_ref}/recording", headers: headers

    expect(response).to have_http_status(:not_found)
  ensure
    FileUtils.rm_f(symlink_path) if defined?(symlink_path) && symlink_path.present?
    FileUtils.rm_f(outside_path) if defined?(outside_path) && outside_path.present?
  end

  def create_recorded_call_session(call_ref, metadata = recording_metadata, recording_ref: metadata['storage_key'])
    conversation = create(:conversation, account: account, inbox: voice_inbox, contact: contact)
    create(
      :telephony_call_session,
      account: account,
      conversation: conversation,
      inbox: voice_inbox,
      contact: contact,
      number_binding: voice_inbox.telephony_number_binding,
      external_call_ref: call_ref,
      recording_ref: recording_ref,
      metadata: { 'recording' => metadata }
    )
  end

  def recording_metadata
    {
      'storage_key' => 'voice-recordings/1/recording-call-1/recording.wav',
      'content_type' => 'audio/wav',
      'byte_size' => 16,
      'source' => 'onelink_runtime'
    }
  end
end
