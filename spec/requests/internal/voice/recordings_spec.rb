require 'rails_helper'

RSpec.describe 'Internal Voice Recording Import API', type: :request do
  let(:account) { create(:account) }
  let(:voice_channel) { create(:channel_voice, :sipuni, account: account, phone_number: '+15550100100') }
  let(:voice_inbox) { voice_channel.inbox }
  let(:conversation) { create(:conversation, account: account, inbox: voice_inbox) }
  let(:call_ref) { 'operator-direct-call-1' }
  let(:sha256) { 'a' * 64 }
  let(:headers) { { 'Authorization' => 'Bearer voice-secret', 'X-Idempotency-Key' => "recording_ready:#{account.id}:#{call_ref}:#{sha256}" } }
  let(:call_session) do
    create(
      :telephony_call_session,
      account: account,
      conversation: conversation,
      inbox: voice_inbox,
      number_binding: voice_inbox.telephony_number_binding,
      external_call_ref: call_ref,
      status: 'completed',
      direction: 'inbound'
    )
  end
  let!(:voice_message) do
    create(
      :message,
      account: account,
      inbox: voice_inbox,
      conversation: conversation,
      content_type: :voice_call,
      message_type: :incoming,
      source_id: "voice_call:#{call_ref}",
      content_attributes: { 'data' => { 'call_sid' => call_ref, 'status' => 'completed' } }
    )
  end
  let(:payload) do
    {
      call_ref: call_ref,
      account_id: account.id,
      source_id: "voice_call:#{call_ref}",
      provider_call_id: 'provider-call-1',
      media_session_ref: 'media-session-1',
      app_ref: 'operator-app-ref',
      ingress_number: '+15550100100',
      caller_number: '+15550100999',
      started_at: 1.minute.ago.iso8601,
      ended_at: Time.current.iso8601,
      download_url: 'https://fonoster.example.test/recordings/operator-direct-call-1.wav?signature=***',
      size_bytes: 123,
      duration_sec: 7,
      sha256: sha256,
      recorded_by: 'janus',
      layout: 'mixed_mono',
      mode: 'operator_direct_bridge'
    }
  end

  before do
    Telephony::NumberBinding.sync_from_voice_channel!(voice_channel)
    call_session
  end

  around do |example|
    with_modified_env(TELEPHONY_RECORDING_IMPORT_ALLOWED_HOSTS: 'fonoster.example.test') do
      example.run
    end
  end

  # rubocop:disable Metrics/MethodLength
  def stored_recording_fixture
    body = "RIFF\x24\x00\x00\x00WAVEfmt janus audio".b
    sha256 = Digest::SHA256.hexdigest(body)
    storage_key = "voice-recordings/janus/#{account.id}/#{call_ref}/#{sha256}.wav"
    path = Rails.root.join('storage', storage_key)
    FileUtils.mkdir_p(path.dirname)
    File.binwrite(path, body)
    payload = {
      call_ref: call_ref,
      account_id: account.id,
      storage_key: storage_key,
      size_bytes: body.bytesize,
      duration_sec: 9,
      sha256: sha256,
      recorded_by: 'janus',
      layout: 'mixed_mono',
      mode: 'operator',
      channels: 1,
      channel_layout: 'mono',
      channel_map: { channel_1: 'user_audio' },
      degraded: true,
      missing_direction: 'peer_audio',
      content_type: 'audio/wav',
      writer: 'janus_recording_postprocessor'
    }
    { path: path, payload: payload, sha256: sha256, storage_key: storage_key }
  end
  # rubocop:enable Metrics/MethodLength

  def post_stored_recording(stored_payload)
    with_modified_env(ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
      post '/internal/voice/recordings/stored',
           params: stored_payload,
           headers: { 'Authorization' => 'Bearer voice-secret' },
           as: :json
    end
  end

  def make_voice_message_recording_stale!
    stale_key = "voice-recordings/sipuni/#{account.id}/#{call_session.id}/browser.webm"
    stale_url = Telephony::CallRecordingPlaybackUrl.path_for(call_session, storage_key: stale_key)
    attributes = voice_message.reload.content_attributes.deep_dup
    attributes['data'] = attributes.fetch('data', {}).merge(
      'recording_ref' => stale_key,
      'recording_url' => stale_url,
      'recording' => { 'recording_ref' => stale_key, 'storage_key' => stale_key, 'recording_url' => stale_url,
                       'recorded_by' => 'browser', 'content_type' => 'audio/webm' }
    )
    voice_message.update!(content_attributes: attributes)
  end

  it 'accepts a valid recording_ready JSON event and enqueues one pull import for duplicate delivery' do
    expect(Telephony::RecordingImportJob).to receive(:perform_later).once

    with_modified_env(ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
      2.times do
        post '/internal/voice/recordings/ready', params: payload, headers: headers, as: :json
        expect(response).to have_http_status(:accepted)
      end
    end

    expect(response.parsed_body).to include(
      'status' => 'accepted',
      'duplicate' => true,
      'call_ref' => call_ref,
      'source_id' => "voice_call:#{call_ref}",
      'message_id' => voice_message.id
    )
    expect(call_session.reload.metadata.dig('recording_import', 'status')).to eq('queued')
  end

  it 'accepts native SIP bridge auth and aliases when source_id/account_id are omitted but call_ref is unique' do
    expect(Telephony::RecordingImportJob).to receive(:perform_later).once

    bridge_payload = payload.except(:account_id, :source_id, :download_url, :size_bytes, :duration_sec).merge(
      recordingUrl: payload[:download_url],
      byteSize: payload[:size_bytes],
      durationMs: 7_001,
      mode: 'operator',
      layout: 'mono'
    )

    with_modified_env(TELEPHONY_BRIDGE_ACCESS_TOKEN: 'bridge-secret') do
      post '/internal/voice/recordings/ready',
           params: bridge_payload,
           headers: { 'Authorization' => 'Bearer bridge-secret' },
           as: :json
    end

    expect(response).to have_http_status(:accepted)
    expect(response.parsed_body).to include(
      'status' => 'accepted',
      'duplicate' => false,
      'call_ref' => call_ref,
      'source_id' => "voice_call:#{call_ref}",
      'message_id' => voice_message.id
    )
    expect(call_session.reload.metadata.dig('recording_import', 'duration_sec')).to eq(8)
    expect(call_session.metadata.dig('recording_import', 'mode')).to eq('operator')
  end

  it 'accepts Janus server recording imports through the internal recording pipeline' do
    expect(Telephony::RecordingImportJob).to receive(:perform_later).once

    janus_payload = payload.merge(
      download_url: 'https://janus-recordings.example.test/recordings/operator-direct-call-1.wav',
      recorded_by: 'janus',
      layout: 'dual_channel',
      mode: 'operator',
      media_session_ref: 'janus-sip-profile-9098'
    )

    with_modified_env(
      ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret',
      TELEPHONY_RECORDING_IMPORT_ALLOWED_HOSTS: 'janus-recordings.example.test'
    ) do
      post '/internal/voice/recordings/ready',
           params: janus_payload,
           headers: headers,
           as: :json
    end

    expect(response).to have_http_status(:accepted)
    expect(response.parsed_body).to include(
      'status' => 'accepted',
      'duplicate' => false,
      'call_ref' => call_ref
    )
    expect(call_session.reload.metadata.dig('recording_import', 'recorded_by')).to eq('janus')
    expect(call_session.metadata.dig('recording_import', 'layout')).to eq('dual_channel')
  end

  it 'accepts already stored Janus recordings without requiring a public download URL' do
    fixture = stored_recording_fixture
    post_stored_recording(fixture[:payload])

    expect(response).to have_http_status(:accepted)
    expect(response.parsed_body).to include(
      'status' => 'ok',
      'call_ref' => call_ref,
      'recording_ref' => fixture[:storage_key]
    )
    expect(call_session.reload.recording_ref).to eq(fixture[:storage_key])
    expect(call_session.metadata['recording']).to include(
      'storage_key' => fixture[:storage_key],
      'sha256' => fixture[:sha256],
      'recorded_by' => 'janus',
      'writer' => 'janus_recording_postprocessor',
      'channels' => 1,
      'channel_layout' => 'mono',
      'channel_map' => { 'channel_1' => 'user_audio' },
      'degraded' => true,
      'missing_direction' => 'peer_audio'
    )
  ensure
    FileUtils.rm_f(fixture[:path]) if defined?(fixture) && fixture.present?
  end

  it 'repairs a stale browser recording URL when the stored Janus callback is retried' do
    fixture = stored_recording_fixture
    post_stored_recording(fixture[:payload])
    make_voice_message_recording_stale!
    post_stored_recording(fixture[:payload])

    repaired_data = voice_message.reload.content_attributes.fetch('data')
    repaired_url = repaired_data.fetch('recording_url')
    repaired_token = Rack::Utils.parse_nested_query(URI.parse(repaired_url).query).fetch('recording_token')
    expect(response).to have_http_status(:accepted)
    expect(response.parsed_body).to include('status' => 'duplicate')
    expect(repaired_data['recording_ref']).to eq(fixture[:storage_key])
    expect(repaired_data.dig('recording', 'storage_key')).to eq(fixture[:storage_key])
    expect(Telephony::CallRecordingPlaybackUrl.valid?(token: repaired_token, call_session: call_session,
                                                      storage_key: fixture[:storage_key])).to be(true)
  ensure
    FileUtils.rm_f(fixture[:path]) if defined?(fixture) && fixture.present?
  end

  it 'repairs stale message recording metadata when recording_ready reports an already stored import' do
    fixture = stored_recording_fixture
    post_stored_recording(fixture[:payload])
    make_voice_message_recording_stale!
    ready_payload = payload.merge(
      sha256: fixture[:sha256],
      size_bytes: fixture[:payload][:size_bytes],
      duration_sec: fixture[:payload][:duration_sec]
    )
    ready_headers = headers.merge(
      'X-Idempotency-Key' => "recording_ready:#{account.id}:#{call_ref}:#{fixture[:sha256]}"
    )

    with_modified_env(ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
      post '/internal/voice/recordings/ready', params: ready_payload, headers: ready_headers, as: :json
    end

    data = voice_message.reload.content_attributes.fetch('data')
    expect(response).to have_http_status(:accepted)
    expect(response.parsed_body).to include('status' => 'duplicate', 'duplicate' => true, 'message_id' => voice_message.id)
    expect(data['recording_ref']).to eq(fixture[:storage_key])
    expect(data.dig('recording', 'storage_key')).to eq(fixture[:storage_key])
  ensure
    FileUtils.rm_f(fixture[:path]) if defined?(fixture) && fixture.present?
  end

  it 'accepts already stored Pipecat dual-channel AI voice recordings' do
    recording_body = "RIFF\x24\x00\x00\x00WAVEfmt pipecat audio".b
    stored_sha256 = Digest::SHA256.hexdigest(recording_body)
    storage_key = "voice-recordings/pipecat/#{account.id}/#{call_ref}/#{stored_sha256}.wav"
    recording_path = Rails.root.join('storage', storage_key)
    FileUtils.mkdir_p(recording_path.dirname)
    File.binwrite(recording_path, recording_body)

    stored_payload = {
      call_ref: call_ref,
      account_id: account.id,
      storage_key: storage_key,
      size_bytes: recording_body.bytesize,
      duration_sec: 9,
      sha256: stored_sha256,
      recorded_by: 'pipecat',
      layout: 'dual_channel',
      mode: 'ai_voice',
      channels: 2,
      channel_layout: 'caller_left_ai_right',
      content_type: 'audio/wav',
      writer: 'pipecat_runtime'
    }

    with_modified_env(ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
      post '/internal/voice/recordings/stored',
           params: stored_payload,
           headers: { 'Authorization' => 'Bearer voice-secret' },
           as: :json
    end

    expect(response).to have_http_status(:accepted)
    expect(call_session.reload.recording_ref).to eq(storage_key)
    expect(call_session.metadata['recording']).to include(
      'storage_key' => storage_key,
      'sha256' => stored_sha256,
      'recorded_by' => 'pipecat',
      'layout' => 'dual_channel',
      'mode' => 'ai_voice',
      'channel_layout' => 'caller_left_ai_right',
      'writer' => 'pipecat_runtime'
    )
  ensure
    FileUtils.rm_f(recording_path) if defined?(recording_path) && recording_path.present?
  end

  it 'rejects stored recording storage keys that clean outside the storage root' do
    stored_payload = {
      call_ref: call_ref,
      account_id: account.id,
      storage_key: 'voice-recordings/../../tmp/recording-secret.wav',
      size_bytes: 12,
      duration_sec: 9,
      sha256: 'b' * 64,
      recorded_by: 'janus',
      layout: 'mixed_mono',
      mode: 'operator',
      content_type: 'audio/wav'
    }

    with_modified_env(ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
      post '/internal/voice/recordings/stored',
           params: stored_payload,
           headers: { 'Authorization' => 'Bearer voice-secret' },
           as: :json
    end

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body).to include('error' => 'INVALID_STORAGE_KEY')
    expect(call_session.reload.recording_ref).to be_nil
  end

  it 'rejects requests without internal voice or bridge auth' do
    post '/internal/voice/recordings/ready', params: payload, as: :json

    expect(response).to have_http_status(:unauthorized)
  end

  it 'rejects AI app recordings so f2498 remains OneLink-runtime owned' do
    with_modified_env(ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
      post '/internal/voice/recordings/ready',
           params: payload.merge(app_ref: 'f2498e07-2bb5-45a1-8c8c-6fecdb4c791a'),
           headers: headers,
           as: :json
    end

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body).to include('error' => 'AI_RECORDING_IMPORT_REJECTED')
  end

  it 'fails closed when source_id does not match the exact voice_call call_ref bubble' do
    with_modified_env(ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
      post '/internal/voice/recordings/ready',
           params: payload.merge(source_id: 'voice_call:other-call'),
           headers: headers,
           as: :json
    end

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body).to include('error' => 'SOURCE_ID_MISMATCH')
  end

  it 'rejects recording downloads outside the allowed HTTPS host policy' do
    with_modified_env(ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
      post '/internal/voice/recordings/ready',
           params: payload.merge(download_url: 'http://127.0.0.1:3000/internal.wav'),
           headers: headers,
           as: :json
    end

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body).to include('error' => 'INVALID_DOWNLOAD_URL')
  end
end
