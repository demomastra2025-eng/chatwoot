require 'rails_helper'

RSpec.describe Telephony::ExternalRecordingCacheService do
  let(:account) { create(:account) }
  let(:external_url) { 'https://sipuni.com/api/crm/record?id=1782816260.483832&hash=recording-signature&user=015856' }
  let(:call_session) do
    create(
      :telephony_call_session,
      account: account,
      provider: 'sipuni',
      recording_ref: external_url,
      metadata: {
        'recording' => {
          'recording_ref' => external_url,
          'recording_url' => external_url
        }
      }
    )
  end
  let(:recording_result) do
    Telephony::ExternalRecordingPlaybackProxy::Result.new(
      data: "ID3\x04sipuni-audio",
      content_type: 'audio/mpeg',
      filename: 'record.mp3'
    )
  end

  after do
    storage_key = call_session.reload.metadata.dig('recording', 'storage_key')
    FileUtils.rm_f(Rails.root.join('storage', storage_key)) if storage_key.present?
  end

  it 'downloads a proxied Sipuni recording into local OneLink storage' do
    allow(Telephony::ExternalRecordingPlaybackProxy).to receive(:fetch).and_return(recording_result)

    result = described_class.cache!(call_session: call_session)

    storage_key = call_session.reload.metadata.dig('recording', 'storage_key')
    expect(result.storage_key).to eq(storage_key)
    expect(storage_key).to start_with("voice-recordings/sipuni/#{account.id}/#{call_session.id}/")
    expect(call_session.recording_ref).to eq(storage_key)
    expect(call_session.metadata.dig('recording', 'external_recording_url')).to eq(external_url)
    expect(call_session.metadata.dig('recording', 'content_type')).to eq('audio/mpeg')
    expect(call_session.metadata.dig('recording', 'byte_size')).to eq(recording_result.data.bytesize)
    expect(call_session.metadata.dig('recording', 'cache_source')).to eq('external_recording_cache')
    expect(File.binread(Rails.root.join('storage', storage_key))).to eq(recording_result.data)
  end

  it 'does not fetch again when the local recording is already cached' do
    storage_key = "voice-recordings/sipuni/#{account.id}/#{call_session.id}/cached.mp3"
    path = Rails.root.join('storage', storage_key)
    FileUtils.mkdir_p(path.dirname)
    File.binwrite(path, recording_result.data)
    call_session.update!(
      recording_ref: storage_key,
      metadata: call_session.metadata.deep_merge('recording' => { 'storage_key' => storage_key })
    )

    expect(Telephony::ExternalRecordingPlaybackProxy).not_to receive(:fetch)

    result = described_class.cache!(call_session: call_session)

    expect(result.storage_key).to eq(storage_key)
  ensure
    FileUtils.rm_f(path) if defined?(path) && path.present?
  end
end
