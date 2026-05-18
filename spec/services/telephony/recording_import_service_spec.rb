require 'rails_helper'

RSpec.describe Telephony::RecordingImportService do
  let(:account) { create(:account) }
  let(:voice_channel) { create(:channel_voice, :fonoster, account: account, phone_number: '+15550100200') }
  let(:voice_inbox) { voice_channel.inbox }
  let(:conversation) { create(:conversation, account: account, inbox: voice_inbox) }
  let(:call_ref) { 'operator-direct-import-1' }
  let(:recording_body) { "RIFF\x10\x00\x00\x00WAVEfmt test audio".b }
  let(:sha256) { Digest::SHA256.hexdigest(recording_body) }
  let(:download_url) { 'https://fonoster.example.test/recordings/operator-direct-import-1.wav?signature=***' }
  let(:payload) do
    {
      'event_key' => "recording_ready:#{account.id}:#{call_ref}:#{sha256}",
      'call_ref' => call_ref,
      'account_id' => account.id,
      'source_id' => "voice_call:#{call_ref}",
      'provider_call_id' => 'provider-call-1',
      'media_session_ref' => 'media-session-1',
      'app_ref' => 'operator-app-ref',
      'download_url' => download_url,
      'size_bytes' => recording_body.bytesize,
      'duration_sec' => 7,
      'sha256' => sha256,
      'recorded_by' => 'fonoster',
      'layout' => 'mixed_mono',
      'mode' => 'operator_direct_bridge'
    }
  end
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
  let!(:legacy_message) do
    create(
      :message,
      account: account,
      inbox: voice_inbox,
      conversation: conversation,
      content_type: :voice_call,
      message_type: :incoming,
      source_id: nil,
      content_attributes: { 'data' => { 'status' => 'completed' } }
    )
  end
  let!(:exact_message) do
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

  before do
    Telephony::NumberBinding.sync_from_voice_channel!(voice_channel)
    call_session
    stub_request(:get, download_url).to_return(status: 200, body: recording_body, headers: { 'Content-Type' => 'audio/wav' })
  end

  around do |example|
    with_modified_env(TELEPHONY_RECORDING_IMPORT_ALLOWED_HOSTS: 'fonoster.example.test') do
      example.run
    end
  end

  after do
    storage_key = call_session.reload.metadata.dig('recording', 'storage_key')
    FileUtils.rm_f(Rails.root.join('storage', storage_key)) if storage_key.present?
  end

  it 'downloads, verifies, stores, and attaches the recording to the exact voice_call source_id bubble', :aggregate_failures do
    result = described_class.new(payload: payload).perform

    call_session.reload
    expect(result).to include(status: 'ok', message_id: exact_message.id)
    expect(call_session.recording_ref).to start_with('voice-recordings/fonoster/')
    expect(call_session.metadata.dig('recording', 'sha256')).to eq(sha256)
    expect(call_session.metadata.dig('recording_import', 'status')).to eq('stored')
    expect(File.binread(Rails.root.join('storage', call_session.recording_ref))).to eq(recording_body)

    exact_data = exact_message.reload.content_attributes.deep_stringify_keys['data']
    legacy_data = legacy_message.reload.content_attributes.deep_stringify_keys['data']
    expect(exact_data['recording_url']).to include('/api/v1/accounts/', 'recording_token=')
    expect(exact_data.dig('recording', 'storage_key')).to eq(call_session.recording_ref)
    expect(legacy_data['recording']).to be_blank
  end

  it 'rejects checksum mismatches without storing a file or updating the dialog' do
    expect do
      described_class.new(payload: payload.merge('sha256' => 'b' * 64)).perform
    end.to raise_error(described_class::NonRetryableError, /checksum mismatch/)

    expect(call_session.reload.recording_ref).to be_blank
    expect(exact_message.reload.content_attributes.deep_stringify_keys.dig('data', 'recording')).to be_blank
  end

  it 'rejects redirects to non-allowed internal hosts before following them' do
    stub_request(:get, download_url).to_return(status: 302, headers: { 'Location' => 'http://127.0.0.1:3000/internal.wav' })

    expect do
      described_class.new(payload: payload).perform
    end.to raise_error(described_class::NonRetryableError, /redirect URL is not allowed/)

    expect(WebMock).not_to have_requested(:get, 'http://127.0.0.1:3000/internal.wav')
  end
end
