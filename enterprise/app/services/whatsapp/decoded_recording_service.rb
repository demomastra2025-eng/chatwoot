require 'tmpdir'
require 'json'

# Explicit local API for the next timed-STT stage. It is not automatically
# enqueued and never reads combined OGG or makes a provider/model request.
class Whatsapp::DecodedRecordingService
  # Failures that prove the currently attached derived result itself is unusable.
  # Only these may downgrade a completed marker, and only for that exact manifest blob.
  DERIVED_RESULT_INVALID = %w[derived_manifest_corrupt derived_manifest_missing derived_chunk_missing derived_chunk_corrupt].freeze

  def initialize(call:, limits: {}, decoder_factory: -> { Whatsapp::NativeOpusDecoder.new })
    @call = call
    @budget = Whatsapp::RecordingDecodeBudget.new(limits: limits)
    @decoder_factory = decoder_factory
  end

  def perform
    @call.reload
    @source = Whatsapp::DecodedRecordingSource.new(call: @call, budget: @budget)
    @publisher = Whatsapp::DecodedRecordingPublisher.new(call: @call, source: @source, budget: @budget)
    return existing_result if @publisher.completed?

    Dir.mktmpdir('onelink-decoded-') do |dir|
      File.chmod(0o700, dir)
      decode_and_publish(dir)
    end
  rescue Whatsapp::NativeOpusDecoder::Unavailable
    unfinished('opus_library_unavailable')
  rescue Whatsapp::RecordingDecodeError => e
    unfinished(e.reason)
  rescue ActiveStorage::FileNotFoundError
    unfinished('source_artifact_missing')
  rescue IOError, SystemCallError, ActiveStorage::IntegrityError
    unfinished('local_decode_io_failed')
  end

  private

  # Transient failures (IO, time budget) while serving a completed result are
  # returned to the caller only; the persisted completed marker stays intact.
  def existing_result
    manifest_blob_id = @call.decoded_recording_manifest.blob.id
    @publisher.existing_result
  rescue Whatsapp::RecordingDecodeError => e
    unfinished(e.reason, invalid_manifest_blob_id: (manifest_blob_id if DERIVED_RESULT_INVALID.include?(e.reason)))
  rescue ActiveStorage::FileNotFoundError
    unfinished('derived_manifest_missing', invalid_manifest_blob_id: manifest_blob_id)
  rescue IOError, SystemCallError
    unfinished('derived_manifest_io_failed')
  end

  def decode_and_publish(dir)
    sink = Whatsapp::RecordingPcmChunks.new(dir: dir, budget: @budget)
    epochs = @source.epochs.map do |epoch|
      decoder = Whatsapp::RecordingEpochDecoder.new(epoch: epoch, sink: sink, budget: @budget, decoder_factory: @decoder_factory)
      decoder.perform { |accept| @source.each_packet(epoch) { |packet| accept.call(packet) } }
    end
    mapping = derived_mapping(epochs, sink.chunks)
    @publisher.perform(mapping: mapping, chunks: sink.chunks)
  ensure
    sink&.close
  end

  def derived_mapping(epochs, chunks)
    too_late = epochs.any? { |epoch| epoch['end_offset_ns'] > @source.manifest['end_offset_ns'] + Whatsapp::RecordingDecodeBudget::MAX_CLOCK_SKEW_NS }
    raise Whatsapp::RecordingDecodeError, 'ambiguous_recording_end' if too_late

    { 'version' => 1, 'state' => 'completed', 'decoder_contract' => Whatsapp::RecordingDecodeBudget::CONTRACT,
      'source_manifest_sha256' => @source.scope[:expected_sha], 'source_sha256' => @source.digest,
      'session_id' => @source.scope[:session], 'account_id' => @source.scope[:account], 'call_id' => @source.scope[:provider_call],
      'origin' => @source.manifest['origin'], 'clock_basis' => 'recorder_observed_anchor_plus_rtp_samples',
      'absolute_sender_alignment' => 'unverified', 'encoder_delay_compensated' => false,
      'sample_rate' => 48_000, 'channels' => 2, 'gap_policy' => 'decoder_state_plc_output_silence',
      'epochs' => epochs, 'chunks' => chunks.map { |chunk| chunk.except('path') } }
  end

  def unfinished(reason, invalid_manifest_blob_id: nil)
    persist_unknown(reason, invalid_manifest_blob_id) if @source
    { 'state' => 'unknown', 'reason' => reason }
  end

  # A failed or stale attempt never replaces the current completed result of the
  # same source and contract, unless that exact derived manifest was proven invalid.
  def persist_unknown(reason, invalid_manifest_blob_id)
    @call.with_lock do
      @call.reload
      next unless @source.current?
      next if @publisher&.completed? && !current_manifest?(invalid_manifest_blob_id)

      meta = (@call.meta || {}).deep_dup
      meta['decoded_recording'] = { 'state' => 'unknown', 'reason' => reason, 'source_sha256' => @source.digest,
                                    'decoder_contract' => Whatsapp::RecordingDecodeBudget::CONTRACT }
      @call.update!(meta: meta)
    end
  end

  def current_manifest?(blob_id)
    blob_id.present? && @call.decoded_recording_manifest.attached? && @call.decoded_recording_manifest.blob.id == blob_id
  end
end
