require 'rails_helper'

RSpec.describe 'Telephony Calls API', type: :request do
  let(:account) { create(:account) }
  let(:administrator) { create(:user, account: account, role: :administrator) }
  let(:headers) { administrator.create_new_auth_token }
  let(:voice_channel) { create(:channel_voice, :sipuni, account: account, phone_number: '+15551230000') }
  let(:voice_inbox) { voice_channel.inbox }
  let(:contact) { create(:contact, account: account, phone_number: '+15551239999', name: 'Voice Contact') }
  let(:path) { "/api/v1/accounts/#{account.id}/telephony/calls/outbound" }

  before do
    account.enable_features!('channel_voice')
  end

  it 'creates a local Janus SIP outbound call session' do
    create(:inbox_member, inbox: voice_inbox, user: administrator)

    post path,
         params: {
           inbox_id: voice_inbox.id,
           contact_id: contact.id
         },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:created)
    expect(response.parsed_body['call_sid']).to start_with('sipuni:local:')

    call_session = account.telephony_call_sessions.find_by!(external_call_ref: response.parsed_body['call_sid'])
    expect(call_session.conversation).to be_present
    expect(call_session.contact_id).to eq(contact.id)
    expect(call_session.inbox_id).to eq(voice_inbox.id)
    expect(call_session.number_binding.number_ref).to eq(voice_inbox.telephony_number_binding.number_ref)
    expect(call_session.status).to eq('created')
    expect(call_session.direction).to eq('outbound')
    expect(call_session.metadata['telephony_call_ref']).to eq(call_session.external_call_ref)
    expect(call_session.conversation.additional_attributes['telephony_call_ref']).to eq(call_session.external_call_ref)
  end

  it 'uses the inbox SIP profile instead of a legacy user agent binding for native SIP outbound calls' do
    create(
      :telephony_agent_binding,
      account: account,
      user: administrator,
      provider: 'sipuni',
      agent_ref: 'legacy-agent-1001',
      agent_aor: 'sip:1001@operator.example.test'
    )
    create(
      :telephony_sip_profile,
      account: account,
      inbox: voice_inbox,
      user: administrator,
      internal_extension: '504',
      sip_username: '015856100014',
      agent_ref: 'local-profile-530-179-504',
      agent_aor: 'sip:504@ats01.kz.sipuni.com',
      availability_mode: 'browser_webphone'
    )

    post path,
         params: {
           inbox_id: voice_inbox.id,
           contact_id: contact.id
         },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:created)
    expect(response.parsed_body['browser_join_supported']).to be(true)

    call_session = account.telephony_call_sessions.find_by!(external_call_ref: response.parsed_body['call_sid'])
    expect(call_session.agent_binding_id).to be_nil
    expect(call_session.metadata['browser_join_supported']).to be(true)
    expect(call_session.metadata.dig('operator_identity', 'operator_identity_source')).to eq('sip_profile')
    expect(call_session.metadata.dig('operator_identity', 'operator_agent_ref')).to eq('local-profile-530-179-504')
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

  it 'stores a browser SIP recording upload and exposes it through the telephony recording route' do
    call_session = create_recorded_call_session(
      'asterisk_analog:local:recording-upload-1',
      {},
      recording_ref: nil,
      provider: 'asterisk_analog'
    )
    call_session.update!(status: 'completed', direction: 'outbound', ended_at: Time.current, duration_seconds: 3)
    mark_call_session_owned_by(call_session, administrator)
    recording_body = 'webm-audio-from-browser'
    upload_file = Tempfile.new(['janus-recording', '.webm'])
    upload_file.binmode
    upload_file.write(recording_body)
    upload_file.rewind

    post "/api/v1/accounts/#{account.id}/telephony/calls/#{CGI.escape(call_session.external_call_ref)}/upload_recording",
         params: {
           recording: Rack::Test::UploadedFile.new(upload_file.path, 'audio/webm', true),
           duration_ms: 3100
         },
         headers: headers

    expect(response).to have_http_status(:created)

    storage_key = call_session.reload.metadata.dig('recording', 'storage_key')
    recording_path = Rails.root.join('storage', storage_key)
    expect(storage_key).to start_with("voice-recordings/asterisk_analog/#{account.id}/#{call_session.id}/")
    expect(call_session).to have_attributes(recording_ref: storage_key)
    expect(call_session.metadata['recording']).to include(
      'content_type' => 'audio/webm',
      'sha256' => Digest::SHA256.hexdigest(recording_body),
      'writer' => 'browser_janus_media_recorder'
    )
    expect(File.binread(recording_path)).to eq(recording_body)

    voice_message = call_session.voice_message_for_current_call
    signed_recording_url = voice_message.content_attributes.dig('data', 'recording_url')
    recording_url_prefix =
      "/api/v1/accounts/#{account.id}/telephony/calls/#{call_session.external_call_ref}/recording?"
    expect(signed_recording_url).to start_with(recording_url_prefix)

    get signed_recording_url

    expect([response.status, response.media_type, response.body]).to eq([200, 'audio/webm', recording_body])
  ensure
    upload_file&.close
    upload_file&.unlink
    FileUtils.rm_f(recording_path) if defined?(recording_path) && recording_path.present?
  end

  it 'rejects browser SIP recording uploads from another inbox-visible user' do
    call_session = create_recorded_call_session(
      'asterisk_analog:local:recording-upload-other-user',
      {},
      recording_ref: nil,
      provider: 'asterisk_analog'
    )
    mark_call_session_owned_by(call_session, administrator)
    other_agent = create(:user, account: account, role: :agent)
    create(:inbox_member, user: other_agent, inbox: voice_inbox)
    metadata = call_session.metadata.to_h.deep_stringify_keys
    metadata['metadata']['operator_candidate_user_ids'] = [other_agent.id]
    call_session.update!(metadata: metadata)
    upload_file = Tempfile.new(['janus-recording-other-user', '.webm'])
    upload_file.binmode
    upload_file.write('other-user-audio')
    upload_file.rewind

    post "/api/v1/accounts/#{account.id}/telephony/calls/#{CGI.escape(call_session.external_call_ref)}/upload_recording",
         params: { recording: Rack::Test::UploadedFile.new(upload_file.path, 'audio/webm', true) },
         headers: other_agent.create_new_auth_token

    expect(response).to have_http_status(:not_found)
    expect(call_session.reload.recording_ref).to be_nil
  ensure
    upload_file&.close
    upload_file&.unlink
  end

  it 'stores a browser SIP recording upload for Sipuni calls when provider recording is unavailable' do
    call_session = create_recorded_call_session(
      'sipuni:local:recording-upload-1',
      {},
      recording_ref: nil,
      provider: 'sipuni'
    )
    mark_call_session_owned_by(call_session, administrator)
    upload_file = Tempfile.new(['sipuni-recording', '.webm'])
    upload_file.binmode
    upload_file.write('duplicate-sipuni-audio')
    upload_file.rewind

    post "/api/v1/accounts/#{account.id}/telephony/calls/#{CGI.escape(call_session.external_call_ref)}/upload_recording",
         params: { recording: Rack::Test::UploadedFile.new(upload_file.path, 'audio/webm', true) },
         headers: headers

    expect(response).to have_http_status(:created)
    storage_key = call_session.reload.metadata.dig('recording', 'storage_key')
    expect(storage_key).to start_with("voice-recordings/sipuni/#{account.id}/#{call_session.id}/")
    expect(call_session.recording_ref).to eq(storage_key)
    expect(call_session.metadata['recording']).to include(
      'content_type' => 'audio/webm',
      'writer' => 'browser_janus_media_recorder'
    )
  ensure
    upload_file&.close
    upload_file&.unlink
    FileUtils.rm_f(Rails.root.join('storage', storage_key)) if defined?(storage_key) && storage_key.present?
  end

  it 'does not accept browser recording uploads with an explicit non-audio content type' do
    call_session = create_recorded_call_session(
      'binotel:local:recording-upload-unsupported-mime',
      {},
      recording_ref: nil,
      provider: 'binotel'
    )
    mark_call_session_owned_by(call_session, administrator)
    upload_file = Tempfile.new(['not-audio-recording', '.webm'])
    upload_file.binmode
    upload_file.write('not-audio')
    upload_file.rewind

    post "/api/v1/accounts/#{account.id}/telephony/calls/#{CGI.escape(call_session.external_call_ref)}/upload_recording",
         params: { recording: Rack::Test::UploadedFile.new(upload_file.path, 'application/x-msdownload', true) },
         headers: headers

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body['code']).to eq('RECORDING_CONTENT_TYPE_UNSUPPORTED')
    expect(call_session.reload.recording_ref).to be_nil
  ensure
    upload_file&.close
    upload_file&.unlink
  end

  it 'streams a signed WhatsApp runtime recording when the call ref contains dots and padding' do
    call_ref = 'whatsapp:wacid.IhggMDBENkUxMUQ3QTNGMzZGMjE0QjVBMTA0QUYwNzM0MjUcGAs3NzA4MDA4NzQyMRUCABUIAA=='
    storage_key = 'voice-recordings/1/whatsapp-wacid-safe/recording.wav'
    call_session = create_recorded_call_session(
      call_ref,
      recording_metadata.merge('storage_key' => storage_key),
      recording_ref: storage_key
    )
    recording_path = Rails.root.join('storage', call_session.metadata.dig('recording', 'storage_key'))
    FileUtils.mkdir_p(recording_path.dirname)
    File.binwrite(recording_path, "RIFF\x24\x00\x00\x00WAVEfmt ")

    get "/api/v1/accounts/#{account.id}/telephony/calls/#{CGI.escape(call_ref)}", headers: headers

    expect(response).to have_http_status(:ok)
    signed_recording_url = response.parsed_body.dig('payload', 'recording_url')
    expect(signed_recording_url).to include('recording_token=')

    get signed_recording_url

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

  it 'returns and redirects to an account-scoped external provider recording URL' do
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

  it 'returns and proxies a Sipuni external recording through a same-origin signed URL' do
    external_url = 'https://sipuni.com/api/crm/record?id=1782816260.483832&hash=recording-signature&user=015856'
    call_session = create_recorded_call_session(
      'sipuni-recording-call',
      recording_metadata.merge('storage_key' => nil, 'recording_ref' => external_url, 'recording_url' => external_url),
      recording_ref: external_url,
      provider: 'sipuni'
    )
    allow(SafeFetch).to receive(:resolve_public_ip!).and_return('93.184.216.34')
    stub_request(:get, external_url)
      .with(headers: { 'User-Agent' => 'OneLink-RecordingPlayback/1.0', 'Range' => 'bytes=0-24575' })
      .to_return(status: 200, body: "RIFF\x24\x00\x00\x00WAVEfmt ", headers: { 'Content-Type' => 'audio/wav' })

    get "/api/v1/accounts/#{account.id}/telephony/calls/#{call_session.external_call_ref}", headers: headers

    expect(response).to have_http_status(:ok)
    signed_recording_url = response.parsed_body.dig('payload', 'recording_url')
    expect(signed_recording_url).to start_with("/api/v1/accounts/#{account.id}/telephony/calls/#{call_session.external_call_ref}/recording?")
    expect(signed_recording_url).to include('recording_token=')

    get signed_recording_url

    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq('audio/wav')
    expect(response.body).to start_with('RIFF')

    cached_storage_key = call_session.reload.metadata.dig('recording', 'storage_key')
    expect(cached_storage_key).to start_with("voice-recordings/sipuni/#{account.id}/#{call_session.id}/")
    expect(File.binread(Rails.root.join('storage', cached_storage_key))).to start_with('RIFF')

    get signed_recording_url

    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq('audio/wav')
    expect(response.body).to start_with('RIFF')
    expect(a_request(:get, external_url).with(headers: { 'Range' => 'bytes=0-24575' })).to have_been_made.once
  ensure
    FileUtils.rm_f(Rails.root.join('storage', cached_storage_key)) if defined?(cached_storage_key) && cached_storage_key.present?
  end

  it 'proxies slow Sipuni recordings with small byte ranges before caching them' do
    external_url = 'https://sipuni.com/api/crm/record?id=1782816261.483833&hash=recording-signature&user=015856'
    call_session = create_recorded_call_session(
      'sipuni-range-recording-call',
      recording_metadata.merge('storage_key' => nil, 'recording_ref' => external_url, 'recording_url' => external_url),
      recording_ref: external_url,
      provider: 'sipuni'
    )
    first_chunk = 'a' * Telephony::ExternalRecordingPlaybackProxy::RANGE_CHUNK_BYTES
    last_chunk = 'b' * 4096
    allow(SafeFetch).to receive(:resolve_public_ip!).and_return('93.184.216.34')
    stub_request(:get, external_url)
      .with(headers: { 'User-Agent' => 'OneLink-RecordingPlayback/1.0', 'Range' => 'bytes=0-24575' })
      .to_return(status: 206, body: first_chunk, headers: { 'Content-Type' => 'audio/mpeg' })
    stub_request(:get, external_url)
      .with(headers: { 'User-Agent' => 'OneLink-RecordingPlayback/1.0', 'Range' => 'bytes=24576-49151' })
      .to_return(status: 206, body: last_chunk, headers: { 'Content-Type' => 'audio/mpeg' })

    get "/api/v1/accounts/#{account.id}/telephony/calls/#{call_session.external_call_ref}", headers: headers
    signed_recording_url = response.parsed_body.dig('payload', 'recording_url')

    get signed_recording_url

    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq('audio/mpeg')
    expect(response.body).to eq(first_chunk + last_chunk)

    cached_storage_key = call_session.reload.metadata.dig('recording', 'storage_key')
    expect(cached_storage_key).to start_with("voice-recordings/sipuni/#{account.id}/#{call_session.id}/")
    expect(call_session.metadata.dig('recording', 'byte_size')).to eq(first_chunk.bytesize + last_chunk.bytesize)
    expect(a_request(:get, external_url).with(headers: { 'Range' => 'bytes=0-24575' })).to have_been_made.once
    expect(a_request(:get, external_url).with(headers: { 'Range' => 'bytes=24576-49151' })).to have_been_made.once
  ensure
    FileUtils.rm_f(Rails.root.join('storage', cached_storage_key)) if defined?(cached_storage_key) && cached_storage_key.present?
  end

  it 'retries a not-yet-ready Sipuni recording range before caching it' do
    external_url = 'https://sipuni.com/api/crm/record?id=1782837791.495454&hash=recording-signature&user=015856'
    call_session = create_recorded_call_session(
      'sipuni-delayed-recording-call',
      recording_metadata.merge('storage_key' => nil, 'recording_ref' => external_url, 'recording_url' => external_url),
      recording_ref: external_url,
      provider: 'sipuni'
    )
    allow(SafeFetch).to receive(:resolve_public_ip!).and_return('93.184.216.34')
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch)
      .with('TELEPHONY_EXTERNAL_RECORDING_RANGE_RETRY_DELAY_SECONDS', anything)
      .and_return('0.001')
    stub_request(:get, external_url)
      .with(headers: { 'User-Agent' => 'OneLink-RecordingPlayback/1.0', 'Range' => 'bytes=0-24575' })
      .to_timeout
      .then
      .to_return(status: 200, body: "ID3\x04incoming", headers: { 'Content-Type' => 'audio/mpeg' })

    get "/api/v1/accounts/#{account.id}/telephony/calls/#{call_session.external_call_ref}", headers: headers
    signed_recording_url = response.parsed_body.dig('payload', 'recording_url')

    get signed_recording_url

    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq('audio/mpeg')
    expect(response.body).to start_with('ID3')

    cached_storage_key = call_session.reload.metadata.dig('recording', 'storage_key')
    expect(cached_storage_key).to start_with("voice-recordings/sipuni/#{account.id}/#{call_session.id}/")
    expect(a_request(:get, external_url).with(headers: { 'Range' => 'bytes=0-24575' })).to have_been_made.twice
  ensure
    FileUtils.rm_f(Rails.root.join('storage', cached_storage_key)) if defined?(cached_storage_key) && cached_storage_key.present?
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

  def create_recorded_call_session(call_ref, metadata = recording_metadata, recording_ref: metadata['storage_key'], provider: 'sipuni')
    conversation = create(:conversation, account: account, inbox: voice_inbox, contact: contact)
    create(
      :telephony_call_session,
      account: account,
      provider: provider,
      conversation: conversation,
      inbox: voice_inbox,
      contact: contact,
      number_binding: voice_inbox.telephony_number_binding,
      external_call_ref: call_ref,
      recording_ref: recording_ref,
      metadata: { 'recording' => metadata }
    )
  end

  def mark_call_session_owned_by(call_session, user)
    metadata = call_session.metadata.to_h.deep_dup.deep_stringify_keys
    route_metadata = metadata['metadata'].is_a?(Hash) ? metadata['metadata'] : {}
    metadata['metadata'] = route_metadata.merge('chatwoot_user_id' => user.id)
    call_session.update!(metadata: metadata)
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
