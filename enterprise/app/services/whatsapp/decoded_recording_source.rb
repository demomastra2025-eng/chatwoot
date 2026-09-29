require 'digest'
require 'json'

class Whatsapp::DecodedRecordingSource
  MAX_CAPTURE_BYTES = 8 * 1024 * 1024
  MAX_CALL_OFFSET_NS = 4 * 3600 * 1_000_000_000

  attr_reader :manifest, :scope, :digest

  def initialize(call:, budget:)
    @call = call
    @budget = budget
    @scope = snapshot
    load_manifest
    @tracks = matching_tracks
    @scope[:tracks] = track_snapshot(@tracks)
    @digest = Digest::SHA256.hexdigest(JSON.generate(@scope))
  end

  def epochs
    groups = []
    active = {}
    captures.each do |artifact|
      key = artifact.values_at('side', 'source_kind', 'generation', 'ssrc')
      if artifact['continuity_reason'] == 'size_limit'
        previous = active[key]
        fail_source!('invalid_epoch_continuity') unless previous && same_codec?(previous['artifacts'].last, artifact)
        previous['artifacts'] << artifact
      else
        validate_new_epoch!(artifact, active[key])
        group = artifact.slice('side', 'source_kind', 'generation', 'ssrc', 'continuity_reason').merge(
          'id' => format('epoch_%06d', groups.size + 1), 'artifacts' => [artifact]
        )
        groups << group
        active[key] = group
      end
    end
    fail_source!('raw_capture_missing') if groups.empty?
    groups
  end

  def each_packet(epoch, &)
    epoch.fetch('artifacts').each do |artifact|
      blob = @tracks.fetch(artifact['id'])
      @budget.check!
      blob.open do |file|
        reader = Whatsapp::RecordingCaptureReader.new(io: file, artifact: artifact, budget: @budget)
        reader.each(&)
      end
    end
  rescue ActiveStorage::IntegrityError
    fail_source!('source_artifact_corrupt')
  end

  def current?
    fresh = snapshot
    fresh[:tracks] = track_snapshot(matching_tracks)
    fresh == @scope && @scope[:decoder_contract] == Whatsapp::RecordingDecodeBudget::CONTRACT
  rescue Whatsapp::RecordingDecodeError
    false
  end

  private

  def snapshot
    bundle = (@call.meta || {})['recording_bundle'] || {}
    ready = bundle_ready?(bundle)
    fail_source!('source_bundle_not_ready') unless ready && @call.media_session_id.present?
    sha = bundle['expected_sha256']
    fail_source!('invalid_source_digest') unless Whatsapp::RecordingBundleManifestValidator::SHA_PATTERN.match?(sha.to_s)

    { call: @call.id, session: @call.media_session_id, account: @call.account_id.to_s, provider_call: @call.provider_call_id,
      expected_sha: sha, manifest_blob: @call.recording_manifest.blob.id,
      decoder_contract: Whatsapp::RecordingDecodeBudget::CONTRACT }
  end

  def bundle_ready?(bundle)
    bundle['version'] == 1 && bundle['completed_sha256'] == bundle['expected_sha256'] && @call.recording_manifest.attached?
  end

  def load_manifest
    blob = @call.recording_manifest.blob
    fail_source!('source_manifest_too_large') if blob.byte_size > Whatsapp::RecordingBundleManifestValidator::MAX_MANIFEST_BYTES
    @budget.check!
    data = blob.download
    @manifest = Whatsapp::RecordingBundleManifestValidator.new(scope: @scope).validate!(data)
    fail_source!('call_duration_limit') if @manifest['end_offset_ns'] > MAX_CALL_OFFSET_NS
  rescue Whatsapp::RecordingBundleManifestValidator::Invalid, Whatsapp::RecordingBundleManifestValidator::Pending,
         Whatsapp::RecordingBundleManifestValidator::Stale
    fail_source!('invalid_source_manifest')
  end

  def captures
    @manifest.fetch('artifacts').select { |artifact| artifact['format'] == 'rtp_framed_v1' }.sort_by { |artifact| artifact['id'] }
  end

  def matching_tracks
    fail_source!('source_track_count_limit') if @call.recording_tracks.blobs.count > 1024
    blobs = @call.recording_tracks.blobs.to_a
    captures.to_h do |artifact|
      matching = blobs.select { |blob| blob.metadata['recording_artifact_id'] == artifact['id'] }
      fail_source!('source_artifact_missing') unless matching.one?
      blob = matching.first
      validate_track!(blob, artifact)
      [artifact['id'], blob]
    end
  end

  def validate_track!(blob, artifact)
    valid = artifact['byte_size'] <= MAX_CAPTURE_BYTES && blob.byte_size == artifact['byte_size'] &&
            blob.metadata['recording_bundle_sha256'] == @scope[:expected_sha] &&
            blob.metadata['recording_artifact_sha256'] == artifact['sha256'] &&
            blob.metadata['recording_bundle_session_id'] == @scope[:session]
    fail_source!('source_artifact_scope_mismatch') unless valid
  end

  def track_snapshot(tracks)
    tracks.sort.to_h.transform_values do |blob|
      { id: blob.id, size: blob.byte_size, checksum: blob.checksum,
        metadata: blob.metadata.slice('recording_artifact_id', 'recording_bundle_sha256',
                                      'recording_artifact_sha256', 'recording_bundle_session_id') }
    end
  end

  def validate_new_epoch!(artifact, previous)
    reason = artifact['continuity_reason']
    valid = (reason == 'source_start' && previous.nil?) || (reason == 'timestamp_reset' && previous.present?)
    fail_source!('invalid_epoch_continuity') unless valid
    supported = artifact['codec'].downcase == 'audio/opus' && artifact['clock_rate'] == Whatsapp::RecordingDecodeBudget::SAMPLE_RATE
    fail_source!('unsupported_codec') unless supported
  end

  def same_codec?(first, second)
    first.values_at('codec', 'clock_rate') == second.values_at('codec', 'clock_rate')
  end

  def fail_source!(reason)
    raise Whatsapp::RecordingDecodeError, reason
  end
end
