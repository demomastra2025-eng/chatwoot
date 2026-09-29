require 'rails_helper'

RSpec.describe Whatsapp::DecodedRecordingService do
  let(:call) { create(:call, status: 'completed', media_session_id: 'synthetic_decoded_session') }
  let(:packets) { synthetic_opus_packets }

  def publish_source(records = [{ packets: packets }])
    artifacts = records.map.with_index { |record, index| source_artifact(record, index) }
    data = JSON.generate(source_manifest(artifacts))
    attach_source_manifest(data)
    data
  end

  def source_artifact(record, index)
    input = record.fetch(:packets)
    offsets = record[:offsets] || input.map.with_index { |_packet, number| 400_000_000 + (number * 20_000_000) }
    data = synthetic_capture(input, offsets: offsets)
    options = { id: format('track_%06d', index + 1), side: record.fetch(:side, 'customer'), generation: record.fetch(:generation, 1),
                reason: record.fetch(:reason, 'source_start'), offsets: offsets }
    artifact = synthetic_capture_artifact(input, data: data, **options).merge(record.fetch(:artifact_change, {}))
    attach_source_track(record.fetch(:data, data), artifact)
    artifact
  end

  def source_manifest(artifacts)
    { 'version' => 1, 'state' => 'final', 'session_id' => call.media_session_id, 'call_id' => call.provider_call_id,
      'account_id' => call.account_id.to_s, 'clock_basis' => 'recorder_observed_monotonic', 'origin' => '2023-11-14T22:13:20Z',
      'end_offset_ns' => artifacts.map { |artifact| artifact['last_offset_ns'] }.max + 600_000_000,
      'decoded_alignment' => 'unknown', 'artifacts' => artifacts }
  end

  def attach_source_manifest(data)
    sha = Digest::SHA256.hexdigest(data)
    call.recording_manifest.attach(io: StringIO.new(data), filename: 'original.json', content_type: 'application/json')
    call.recording_tracks.blobs.each { |blob| blob.update!(metadata: blob.metadata.merge('recording_bundle_sha256' => sha)) }
    call.update!(meta: (call.meta || {}).merge('recording_bundle' => { 'version' => 1, 'expected_sha256' => sha, 'completed_sha256' => sha }))
  end

  def attach_source_track(data, artifact)
    metadata = { 'recording_artifact_id' => artifact['id'], 'recording_artifact_sha256' => artifact['sha256'],
                 'recording_bundle_session_id' => call.media_session_id, 'recording_bundle_sha256' => 'pending' }
    blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new(data), filename: "#{artifact['id']}.rtp",
                                                  content_type: 'application/vnd.onelink.rtp-capture', metadata: metadata, identify: false)
    call.recording_tracks.attach(blob)
  end

  def perform_decode(**arguments)
    described_class.new(call: call, **arguments).perform
  end

  it 'publishes native bounded WAV and a separate versioned mapping while preserving original playback and manifest' do
    original = publish_source
    source_blob = call.recording_manifest.blob.id
    call.recording.attach(io: StringIO.new('synthetic playback'), filename: 'combined.ogg', content_type: 'audio/ogg')
    playback_blob = call.recording.blob.id
    expect(Whatsapp::MediaServerClient).not_to receive(:new)
    expect(Whatsapp::CallTranscriptionJob).not_to receive(:perform_later)

    result = perform_decode

    expect(result['state']).to eq('completed')
    expect(result['mapping']).to include('version' => 1, 'clock_basis' => 'recorder_observed_anchor_plus_rtp_samples',
                                         'absolute_sender_alignment' => 'unverified', 'encoder_delay_compensated' => false)
    expect(result['chunks'].first).to include('sample_count' => 19_200, 'start_offset_ns' => 400_000_000, 'end_offset_ns' => 800_000_000)
    expect_native_wav
    expect_preserved_sources(source_blob, original, playback_blob)
    expect(JSON.generate(result)).not_to include('/tmp/', 'path')
  end

  def expect_native_wav
    wav = call.reload.decoded_recording_chunks.first.download
    expect(wav.byteslice(0, 4)).to eq('RIFF')
    expect(wav.byteslice(40, 4).unpack1('V')).to eq(19_200 * 4)
  end

  def expect_preserved_sources(source_blob, original, playback_blob)
    expect(call.recording_manifest.blob.id).to eq(source_blob)
    expect(call.recording_manifest.download).to eq(original)
    expect(call.recording.blob.id).to eq(playback_blob)
  end

  it 'returns existing output on retry without decoding or adding attachments again' do
    publish_source
    first = perform_decode
    expect(Whatsapp::NativeOpusDecoder).not_to receive(:new)
    second = perform_decode
    expect(second).to eq(first)
    expect(call.reload.decoded_recording_chunks.count).to eq(1)
  end

  it 'fences retry when its derived manifest is removed during download' do
    publish_source
    perform_decode
    derived_blob = call.reload.decoded_recording_manifest.blob
    allow(derived_blob.service).to receive(:download).and_wrap_original do |method, key, &block|
      data = method.call(key, &block)
      call.decoded_recording_manifest.detach if key == derived_blob.key
      data
    end
    expect(perform_decode).to eq('state' => 'unknown', 'reason' => 'stale_source')
  end

  it 'preserves decoder state through capture size_limit segments' do
    first = packets[0, 10]
    last = packets[10..]
    publish_source([{ packets: first }, { packets: last, reason: 'size_limit', offsets: (10...20).map do |index|
      400_000_000 + (index * 20_000_000)
    end }])
    expect(Whatsapp::NativeOpusDecoder).to receive(:new).once.and_call_original
    result = perform_decode
    expect(result['mapping']['epochs'].size).to eq(1)
    expect(result['mapping']['epochs'].first).to include('timeline_samples' => 19_200, 'artifact_ids' => %w[track_000001 track_000002])
  end

  it 'starts fresh native epochs for explicit reset and retains the pause between them' do
    reset = synthetic_opus_packets(durations: Array.new(10, 960), timestamp: 100, sequence: 100)
    publish_source([{ packets: packets }, { packets: reset, reason: 'timestamp_reset', offsets: (0...10).map do |index|
      1_100_000_000 + (index * 20_000_000)
    end }])
    expect(Whatsapp::NativeOpusDecoder).to receive(:new).twice.and_call_original
    epochs = perform_decode['mapping']['epochs']
    expect(epochs.map { |epoch| epoch['origin_offset_ns'] }).to eq([400_000_000, 1_100_000_000])
    expect(epochs.map { |epoch| epoch['end_offset_ns'] }).to eq([800_000_000, 1_300_000_000])
  end

  it 'retains overlapping customer and late agent audio as separate source roles' do
    agent = synthetic_opus_packets(ssrc: 4321, frequency: 1300)
    publish_source([{ packets: packets }, { packets: agent, side: 'agent', generation: 2,
                                            offsets: (0...20).map { |index| 650_000_000 + (index * 20_000_000) } }])
    chunks = perform_decode['chunks']
    expect(chunks.map { |chunk| chunk['side'] }).to eq(%w[customer agent])
    expect(chunks.map { |chunk| chunk['start_offset_ns'] }).to eq([400_000_000, 650_000_000])
    expect(chunks.map { |chunk| chunk['end_offset_ns'] }).to eq([800_000_000, 1_050_000_000])
  end

  it 'uses separate native epochs after a new generation reuses the same SSRC' do
    publish_source([{ packets: packets }, { packets: packets, generation: 2, offsets: (0...20).map do |index|
      1_100_000_000 + (index * 20_000_000)
    end }])
    result = perform_decode
    expect(result['mapping']['epochs'].map { |epoch| epoch['generation'] }).to eq([1, 2])
  end

  it 'keeps missing library explicit and unfinished while Rails classes remain usable' do
    original = publish_source
    factory = -> { raise Whatsapp::NativeOpusDecoder::Unavailable, 'synthetic missing library' }
    expect(perform_decode(decoder_factory: factory)).to eq('state' => 'unknown', 'reason' => 'opus_library_unavailable')
    expect(call.reload.meta.dig('decoded_recording', 'state')).to eq('unknown')
    expect(call.decoded_recording_manifest).not_to be_attached
    expect(call.recording_manifest.download).to eq(original)
  end

  it 'keeps unsupported codecs raw without declaring them decoded Opus' do
    publish_source([{ packets: packets, artifact_change: { 'codec' => 'audio/pcma', 'clock_rate' => 8000 } }])
    expect(perform_decode).to eq('state' => 'unknown', 'reason' => 'unsupported_codec')
    expect(call.reload.decoded_recording_chunks.count).to eq(0)
    expect(call.recording_tracks.count).to eq(1)
  end

  it 'keeps corrupt native packets unfinished without publishing decoded attachments' do
    bad = packets.first.byteslice(0, 12) + "\xff".b
    publish_source([{ packets: [bad] }])
    expect(perform_decode['state']).to eq('unknown')
    expect(call.reload.decoded_recording_manifest).not_to be_attached
  end

  it 'detects actual source bytes that disagree with the stored manifest SHA' do
    data = synthetic_capture(packets).dup
    data[7, 8] = [401_000_000].pack('Q>')
    publish_source([{ packets: packets, data: data }])
    expect(perform_decode).to eq('state' => 'unknown', 'reason' => 'invalid_capture')
    expect(call.reload.decoded_recording_chunks.count).to eq(0)
  end

  it 'leaves explicit unknown on output ceilings and cleans private temporary files' do
    publish_source
    temporary = []
    allow(Dir).to receive(:mktmpdir).and_wrap_original do |method, *arguments, &block|
      method.call(*arguments) do |dir|
        temporary << dir
        block.call(dir)
      end
    end
    expect(perform_decode(limits: { output_bytes: 100 })).to eq('state' => 'unknown', 'reason' => 'output_bytes_limit')
    expect(call.reload.decoded_recording_chunks.count).to eq(0)
    expect(temporary).not_to be_empty
    expect(temporary.none? { |dir| File.exist?(dir) }).to be(true)
  end

  %w[media_session_id account_id provider_call_id source_artifact decoder_contract].each do |field|
    it "fences late publication after #{field} changes" do
      publish_source
      allow(ActiveStorage::Blob).to receive(:create_and_upload!).and_wrap_original do |method, **arguments|
        blob = method.call(**arguments)
        mutate_decode_scope(field) if arguments[:filename] == 'chunk_000001.wav'
        blob
      end
      expect(perform_decode).to eq('state' => 'unknown', 'reason' => 'stale_source')
      expect(call.reload.decoded_recording_manifest).not_to be_attached
      expect(call.decoded_recording_chunks.count).to eq(0)
      expect(call.meta.dig('decoded_recording', 'state')).not_to eq('completed')
    end
  end

  def mutate_decode_scope(field)
    case field
    when 'source_artifact'
      blob = call.recording_tracks.first.blob
      blob.update!(metadata: blob.metadata.merge('recording_artifact_sha256' => 'a' * 64))
    when 'decoder_contract'
      stub_const('Whatsapp::RecordingDecodeBudget::CONTRACT', 'synthetic-new-contract')
    when 'account_id'
      call.update!(account_id: create(:account).id)
    else
      call.update!(field => 'synthetic-changed-scope')
    end
  end

  it 'rolls back native attachments when completion metadata cannot be saved' do
    publish_source
    allow(call).to receive(:update!).with(meta: anything).and_raise(ActiveRecord::RecordInvalid.new(call))
    expect { perform_decode }.to raise_error(ActiveRecord::RecordInvalid)
    expect(call.reload.decoded_recording_manifest).not_to be_attached
    expect(call.decoded_recording_chunks.count).to eq(0)
  end

  it 'does not treat a missing required source artifact as a completed empty recording' do
    publish_source
    call.recording_tracks.detach
    expect(perform_decode).to eq('state' => 'unknown', 'reason' => 'source_artifact_missing')
  end

  it 'leaves unknown when a required stored source object has disappeared' do
    publish_source
    blob = call.recording_tracks.first.blob
    blob.service.delete(blob.key)
    expect(perform_decode).to eq('state' => 'unknown', 'reason' => 'source_artifact_missing')
    expect(call.reload.decoded_recording_chunks.count).to eq(0)
  end

  it 'deduplicates native chunks after a interrupted completion marker is retried' do
    publish_source
    original = perform_decode
    blobs = call.reload.decoded_recording_chunks.blobs.pluck(:id)
    call.update!(meta: call.meta.deep_merge('decoded_recording' => { 'state' => 'unknown' }))
    result = perform_decode
    expect(result['state']).to eq('completed')
    expect(call.reload.decoded_recording_chunks.blobs.pluck(:id)).to eq(blobs)
    expect(result['mapping']).to eq(original['mapping'])
  end

  describe 'completed marker protection and re-derivation' do
    def other_native_build
      -> { Whatsapp::NativeOpusDecoder.new.tap { |decoder| decoder.instance_variable_set(:@version, 'libopus 9.9.9-synthetic') } }
    end

    def decoded_state
      call.reload.meta.dig('decoded_recording', 'state')
    end

    it 'R1: a slower failing attempt of the same source never downgrades the completed result' do
      publish_source
      winner = nil
      racing = described_class.new(call: Call.find(call.id), decoder_factory: lambda {
        winner = described_class.new(call: Call.find(call.id)).perform
        raise Whatsapp::NativeOpusDecoder::Unavailable, 'synthetic worker without libopus'
      })
      expect(racing.perform).to eq('state' => 'unknown', 'reason' => 'opus_library_unavailable')
      expect(winner['state']).to eq('completed')
      expect(decoded_state).to eq('completed')
      expect(perform_decode).to eq(winner)
    end

    it 'R2: transient errors while serving a completed result are returned to the caller only' do
      publish_source
      first = perform_decode
      derived = call.reload.decoded_recording_manifest.blob
      failures = 0
      allow(derived.service).to receive(:download).and_wrap_original do |method, key, &block|
        raise Errno::ECONNRESET if key == derived.key && (failures += 1) == 1

        method.call(key, &block)
      end
      expect(perform_decode).to eq('state' => 'unknown', 'reason' => 'derived_manifest_io_failed')
      expect(perform_decode(limits: { mapping_bytes: 1 })).to eq('state' => 'unknown', 'reason' => 'mapping_size_limit')
      expect(decoded_state).to eq('completed')
      expect(perform_decode).to eq(first)
    end

    it 'reports a missing derived manifest object distinctly and re-derives only that exact result' do
      publish_source
      first = perform_decode
      derived = call.reload.decoded_recording_manifest.blob
      chunk_ids = call.decoded_recording_chunks.blobs.pluck(:id)
      derived.service.delete(derived.key)
      allow(Whatsapp::NativeOpusDecoder).to receive(:new).and_call_original
      expect(perform_decode).to eq('state' => 'unknown', 'reason' => 'derived_manifest_missing')
      expect(Whatsapp::NativeOpusDecoder).not_to have_received(:new)
      expect(call.reload.meta['decoded_recording']).to include('state' => 'unknown', 'reason' => 'derived_manifest_missing')
      healed = perform_decode
      expect(Whatsapp::NativeOpusDecoder).to have_received(:new).once
      expect(healed.except('manifest_blob_id')).to eq(first.except('manifest_blob_id'))
      expect(call.reload.decoded_recording_manifest.blob.id).not_to eq(derived.id)
      expect(call.decoded_recording_chunks.blobs.pluck(:id)).to eq(chunk_ids)
    end

    it 'R3: another native libopus build re-derives after a downgrade and supersedes the old chunks' do
      publish_source
      perform_decode
      old_chunks = call.reload.decoded_recording_chunks.blobs.to_a
      call.update!(meta: call.meta.deep_merge('decoded_recording' => { 'state' => 'unknown', 'reason' => 'local_decode_io_failed' }))
      results = Array.new(2) { perform_decode(decoder_factory: other_native_build) }
      expect(results.map { |result| result['state'] }).to eq(%w[completed completed])
      expect(results.last).to eq(results.first)
      expect(results.last['mapping']['epochs'].first['decoder_version']).to eq('libopus 9.9.9-synthetic')
      expect_superseded(old_chunks, results.last)
    end

    it 'R6: a decoder contract bump re-derives an already completed call' do
      publish_source
      perform_decode
      old_chunks = call.reload.decoded_recording_chunks.blobs.to_a
      stub_const('Whatsapp::RecordingDecodeBudget::CONTRACT', 'opus_pcm_mapping_v2')
      bumped = perform_decode
      expect(bumped['state']).to eq('completed')
      expect(bumped['mapping']['decoder_contract']).to eq('opus_pcm_mapping_v2')
      expect_superseded(old_chunks, bumped)
      expect(perform_decode).to eq(bumped)
    end

    it 'reports a newer completed marker that lands while an older one is served as stale_source without downgrading it' do
      publish_source
      perform_decode
      rederived = false
      allow(Whatsapp::DecodedRecordingSource).to receive(:new).and_wrap_original do |method, **arguments|
        source = method.call(**arguments)
        unless rederived
          rederived = true
          other = Call.find(call.id)
          other.update!(meta: other.meta.deep_merge('decoded_recording' => { 'state' => 'unknown', 'reason' => 'local_decode_io_failed' }))
          described_class.new(call: Call.find(call.id), decoder_factory: other_native_build).perform
        end
        source
      end
      expect(perform_decode).to eq('state' => 'unknown', 'reason' => 'stale_source')
      newer = call.reload.meta['decoded_recording']
      expect(newer['state']).to eq('completed')
      expect(Digest::SHA256.hexdigest(call.decoded_recording_manifest.download)).to eq(newer['mapping_sha256'])
      expect(perform_decode['mapping']['epochs'].first['decoder_version']).to eq('libopus 9.9.9-synthetic')
    end

    it 'keeps a more informative unknown reason when a concurrent downgrade fences the served result' do
      publish_source
      perform_decode
      derived_blob = call.reload.decoded_recording_manifest.blob
      allow(derived_blob.service).to receive(:download).and_wrap_original do |method, key, &block|
        data = method.call(key, &block)
        if key == derived_blob.key
          other = Call.find(call.id)
          other.update!(meta: other.meta.deep_merge('decoded_recording' => { 'state' => 'unknown', 'reason' => 'derived_chunk_corrupt' }))
        end
        data
      end
      expect(perform_decode).to eq('state' => 'unknown', 'reason' => 'stale_source')
      expect(call.reload.meta['decoded_recording']).to include('state' => 'unknown', 'reason' => 'derived_chunk_corrupt')
    end

    def expect_superseded(old_chunks, result)
      expect(old_chunks.size).to eq(1)
      current = call.reload.decoded_recording_chunks.blobs.pluck(:id)
      expect(current).to eq(result['chunks'].pluck('blob_id'))
      expect(current & old_chunks.map(&:id)).to be_empty
      expect_purged_without_touching_sources(old_chunks)
    end

    def expect_purged_without_touching_sources(old_chunks)
      expect(ActiveStorage::Attachment.where(blob_id: old_chunks.map(&:id))).to be_empty
      old_chunks.each { |blob| expect(ActiveStorage::PurgeJob).to have_been_enqueued.with(blob) }
      expect(call.recording_tracks.count).to eq(1)
      expect(call.recording_manifest).to be_attached
    end
  end
end
