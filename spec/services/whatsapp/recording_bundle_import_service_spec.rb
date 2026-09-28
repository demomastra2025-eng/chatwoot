require 'rails_helper'

RSpec.describe Whatsapp::RecordingBundleImportService do
  let(:call) { create(:call, status: 'completed', media_session_id: 'session_test') }
  let(:client) { instance_double(Whatsapp::MediaServerClient) }
  let(:packet) { [0x80, 111, 1, 960, 1234].pack('CCnNN') + "\xf8\xff\xfe".b }
  let(:capture) { "OLRTP1\n".b + [400_000_000, packet.bytesize].pack('Q>L>') + packet }
  let(:artifact) do
    { 'id' => 'track_000001', 'format' => 'rtp_framed_v1', 'side' => 'customer', 'source_kind' => 'meta', 'generation' => 1,
      'codec' => 'audio/opus', 'clock_rate' => 48_000, 'ssrc' => 1234, 'first_offset_ns' => 400_000_000,
      'last_offset_ns' => 400_000_000, 'packets' => 1, 'rtp_ticks' => 0, 'unordered_packets' => 0, 'timestamp_wraps' => 0,
      'first_rtp_timestamp' => 960, 'last_rtp_timestamp' => 960,
      'byte_size' => capture.bytesize, 'sha256' => Digest::SHA256.hexdigest(capture) }
  end
  let(:manifest) do
    { 'version' => 1, 'state' => 'final', 'session_id' => call.media_session_id, 'call_id' => call.provider_call_id,
      'account_id' => call.account_id.to_s, 'clock_basis' => 'recorder_observed_monotonic',
      'origin' => '2023-11-14T22:13:20Z', 'end_offset_ns' => 5_600_000_000, 'decoded_alignment' => 'unknown', 'artifacts' => [artifact] }
  end

  before do
    publish_manifest
    allow(client).to receive(:download_recording_artifact).with('session_test', 'track_000001', account_id: call.account_id.to_s,
                                                                                                call_id: call.provider_call_id).and_return(capture)
  end

  def publish_manifest(data = JSON.generate(manifest))
    call.update!(meta: (call.meta || {}).merge('recording_bundle' => { 'version' => 1, 'expected_sha256' => Digest::SHA256.hexdigest(data) }))
    allow(client).to receive(:download_recording_manifest).with('session_test', account_id: call.account_id.to_s,
                                                                                call_id: call.provider_call_id).and_return(data)
  end

  def perform_import
    described_class.new(call: call, client: client).perform
  end

  it 'imports lossless capture and manifest with explicit unknown decoded alignment' do
    perform_import

    expect(call.reload.recording_tracks.count).to eq(1)
    expect(call.recording_tracks.first.download).to eq(capture)
    expect(call.recording_manifest.download).to eq(JSON.generate(manifest))
    expect(call.meta.dig('recording_bundle', 'completed_sha256')).to eq(Digest::SHA256.hexdigest(JSON.generate(manifest)))
    expect(call.meta.dig('recording_bundle', 'decoded_alignment')).to eq('unknown')
    expect(call.recording).not_to be_attached
  end

  it 'does not download or append tracks again after completion' do
    perform_import
    expect(client).not_to receive(:download_recording_manifest)
    expect(client).not_to receive(:download_recording_artifact)

    perform_import

    expect(call.reload.recording_tracks.count).to eq(1)
  end

  it 'imports a bundle after combined playback has already been attached' do
    call.recording.attach(io: StringIO.new('combined'), filename: 'combined.ogg', content_type: 'audio/ogg')
    existing = call.recording.blob.id
    perform_import

    expect(call.reload.recording.blob.id).to eq(existing)
    expect(call.recording_tracks.count).to eq(1)
  end

  it 'repairs the job combined-first path without terminating or downloading combined again' do
    call.recording.attach(io: StringIO.new('combined'), filename: 'combined.ogg', content_type: 'audio/ogg')
    allow(Whatsapp::MediaServerClient).to receive(:new).and_return(client)
    allow(Whatsapp::CallMessageBuilder).to receive(:update_recording_url!)
    allow(Whatsapp::CallTranscriptionJob).to receive(:perform_later)
    expect(client).not_to receive(:terminate_session)
    expect(client).not_to receive(:download_recording)

    Whatsapp::CallRecordingFetchJob.perform_now(call.id)

    expect(call.reload.recording_manifest).to be_attached
    expect(call.recording_tracks.count).to eq(1)
  end

  it 'deduplicates an artifact attached before a crash left the completed marker missing' do
    metadata = { 'recording_artifact_id' => artifact['id'], 'recording_bundle_sha256' => Digest::SHA256.hexdigest(JSON.generate(manifest)),
                 'recording_artifact_sha256' => artifact['sha256'], 'recording_bundle_session_id' => 'session_test' }
    blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new(capture), filename: 'recovered.rtp',
                                                  content_type: 'application/vnd.onelink.rtp-capture', metadata: metadata, identify: false)
    call.recording_tracks.attach(blob)
    blob.update!(metadata: blob.metadata.merge('analyzed' => true))

    perform_import

    expect(call.reload.recording_tracks.blobs.pluck(:id)).to eq([blob.id])
    expect(call.meta.dig('recording_bundle', 'completed_sha256')).to be_present
  end

  it 'does not complete or fall back to legacy for an explicitly expected missing manifest' do
    allow(client).to receive(:download_recording_manifest).and_raise(Whatsapp::MediaServerClient::SessionError.new('missing', http_status: 404))

    expect { perform_import }.to raise_error(described_class::Pending)
    expect(call.reload.recording_manifest).not_to be_attached
    expect(call.meta.dig('recording_bundle', 'completed_sha256')).to be_nil
  end

  it 'keeps a missing required artifact retryable without publishing completed' do
    allow(client).to receive(:download_recording_artifact).and_raise(Whatsapp::MediaServerClient::SessionError.new('missing', http_status: 404))

    expect { perform_import }.to raise_error(described_class::Pending)
    expect(call.reload.recording_tracks.count).to eq(0)
    expect(call.recording_manifest).not_to be_attached
    expect(call.meta.dig('recording_bundle', 'completed_sha256')).to be_nil
  end

  it 'rejects partial and failed manifests even when their digest matches the ready signal' do
    manifest['state'] = 'partial'
    publish_manifest

    expect { perform_import }.to raise_error(described_class::Pending)
    expect(call.reload.recording_tracks.count).to eq(0)
  end

  it 'rejects unsupported versions without publishing completed' do
    manifest['version'] = 2
    publish_manifest

    expect { perform_import }.to raise_error(described_class::Invalid)
    expect(call.reload.recording_manifest).not_to be_attached
  end

  %w[session_id account_id call_id].each do |key|
    it "rejects a foreign manifest #{key} without changing attachments" do
      manifest[key] = 'foreign'
      publish_manifest

      expect { perform_import }.to raise_error(described_class::Stale)
      expect(call.reload.recording_tracks.count).to eq(0)
      expect(call.recording_manifest).not_to be_attached
    end
  end

  %w[media_session_id provider_call_id account_id expected_sha256].each do |key|
    it "rechecks #{key} under lock after downloads without changing attachments" do
      allow(client).to receive(:download_recording_artifact) do
        change_import_scope(key)
        capture
      end

      expect { perform_import }.to raise_error(described_class::Stale)
      expect(call.reload.recording_tracks.count).to eq(0)
      expect(call.recording_manifest).not_to be_attached
      expect(call.meta.dig('recording_bundle', 'completed_sha256')).to be_nil
    end
  end

  def change_import_scope(key)
    if key == 'expected_sha256'
      call.update!(meta: call.meta.deep_merge('recording_bundle' => { key => 'a' * 64 }))
    else
      value = key == 'account_id' ? create(:account).id : 'changed_scope'
      call.update!(key => value)
    end
  end

  it 'leaves all attachments unchanged when a later required artifact is missing' do
    manifest['artifacts'] << artifact.merge('id' => 'track_000002', 'side' => 'agent', 'source_kind' => 'browser', 'generation' => 2)
    publish_manifest
    allow(client).to receive(:download_recording_artifact).with('session_test', 'track_000002', account_id: call.account_id.to_s,
                                                                                                call_id: call.provider_call_id)
                                                          .and_raise(Whatsapp::MediaServerClient::SessionError.new('missing', http_status: 404))

    expect { perform_import }.to raise_error(described_class::Pending)
    expect(call.reload.recording_tracks.count).to eq(0)
    expect(call.recording_manifest).not_to be_attached
    expect(call.meta.dig('recording_bundle', 'completed_sha256')).to be_nil
  end

  it 'rolls back attachments when the completion marker cannot be committed' do
    allow(call).to receive(:update!).with(meta: anything).and_raise(ActiveRecord::RecordInvalid.new(call))

    expect { perform_import }.to raise_error(ActiveRecord::RecordInvalid)
    expect(call.reload.recording_tracks.count).to eq(0)
    expect(call.recording_manifest).not_to be_attached
    expect(call.meta.dig('recording_bundle', 'completed_sha256')).to be_nil
  end

  it 'rejects a corrupted artifact before attaching any bundle data' do
    allow(client).to receive(:download_recording_artifact).and_return('corrupt')

    expect { perform_import }.to raise_error(described_class::Pending)
    expect(call.reload.recording_tracks.count).to eq(0)
    expect(call.recording_manifest).not_to be_attached
  end

  it 'rejects a truncated capture even if its size and digest are declared by the manifest' do
    truncated = capture.byteslice(0, capture.bytesize - 1)
    artifact['sha256'] = Digest::SHA256.hexdigest(truncated)
    artifact['byte_size'] = truncated.bytesize
    publish_manifest
    allow(client).to receive(:download_recording_artifact).and_return(truncated)

    expect { perform_import }.to raise_error(described_class::Invalid)
    expect(call.reload.recording_tracks.count).to eq(0)
  end

  it 'rejects duplicate or path-like artifact IDs before any artifact download' do
    artifact['id'] = '../foreign'
    publish_manifest
    expect(client).not_to receive(:download_recording_artifact)

    expect { perform_import }.to raise_error(described_class::Invalid)
    expect(call.reload.recording_tracks.count).to eq(0)
  end

  it 'commits a final absent-side bundle without inventing any audio tracks' do
    manifest['artifacts'] = []
    publish_manifest

    perform_import

    expect(call.reload.recording_tracks.count).to eq(0)
    expect(call.recording_manifest).to be_attached
    expect(call.meta.dig('recording_bundle', 'artifact_count')).to eq(0)
  end

  it 'keeps combined playback repair available while the bundle is temporarily missing' do
    call.recording.attach(io: StringIO.new('combined'), filename: 'combined.ogg', content_type: 'audio/ogg')
    allow(Whatsapp::MediaServerClient).to receive(:new).and_return(client)
    allow(client).to receive(:download_recording_manifest).and_raise(Whatsapp::MediaServerClient::SessionError.new('missing', http_status: 404))
    allow(Whatsapp::CallMessageBuilder).to receive(:update_recording_url!)
    allow(Whatsapp::CallTranscriptionJob).to receive(:perform_later)

    Whatsapp::CallRecordingFetchJob.perform_now(call.id)

    expect(Whatsapp::CallMessageBuilder).to have_received(:update_recording_url!)
    expect(call.reload.recording).to be_attached
    expect(call.meta.dig('recording_bundle', 'completed_sha256')).to be_nil
  end

  it 'rejects a conflicting previously attached artifact without replacing it' do
    call.recording_tracks.attach(io: StringIO.new('foreign capture'), filename: 'existing.rtp', content_type: 'application/vnd.onelink.rtp-capture',
                                 metadata: { 'recording_artifact_id' => artifact['id'] })
    existing_id = call.recording_tracks.first.blob.id

    expect { perform_import }.to raise_error(described_class::Invalid)
    expect(call.reload.recording_tracks.blobs.pluck(:id)).to eq([existing_id])
    expect(call.meta.dig('recording_bundle', 'completed_sha256')).to be_nil
  end

  it 'rejects a final manifest that declares a capture error' do
    manifest['error_code'] = 'capture_write_failed'
    publish_manifest

    expect { perform_import }.to raise_error(described_class::Pending)
    expect(call.reload.recording_manifest).not_to be_attached
  end
end
