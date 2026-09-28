require 'digest'
require 'json'

class Whatsapp::RecordingBundleImportService
  class Pending < StandardError; end
  class Invalid < StandardError; end
  class Stale < StandardError; end

  SHA_PATTERN = /\A[0-9a-f]{64}\z/

  def initialize(call:, client:)
    @call = call
    @client = client
    @created_blobs = []
  end

  def perform
    @call.reload
    @scope = scope_snapshot
    return if completed?

    data = bundle_download { @client.download_recording_manifest(@scope[:session], account_id: @scope[:account], call_id: @scope[:provider_call]) }
    @manifest = validate_manifest(data)
    staged = @manifest.fetch('artifacts').map { |artifact| stage_artifact(artifact) }
    manifest_blob = upload_blob(data, "call_#{@call.id}_manifest.json", 'application/json', {})
    commit_import(staged, manifest_blob)
  ensure
    @created_blobs.each { |blob| blob.purge_later unless blob.attachments.exists? }
  end

  private

  def scope_snapshot
    bundle = (@call.meta || {})['recording_bundle'] || {}
    raise Stale, 'Recording bundle signal missing' unless bundle['version'] == 1 && @call.media_session_id.present?
    raise Invalid, 'Invalid expected manifest digest' unless SHA_PATTERN.match?(bundle['expected_sha256'].to_s)

    { session: @call.media_session_id, account: @call.account_id.to_s, provider_call: @call.provider_call_id,
      expected_sha: bundle['expected_sha256'] }
  end

  def completed?
    (@call.meta || {}).dig('recording_bundle', 'completed_sha256') == @scope[:expected_sha] && @call.recording_manifest.attached?
  end

  def validate_manifest(data)
    Whatsapp::RecordingBundleManifestValidator.new(scope: @scope).validate!(data)
  rescue Whatsapp::RecordingBundleManifestValidator::Pending => e
    raise Pending, e.message
  rescue Whatsapp::RecordingBundleManifestValidator::Invalid => e
    raise Invalid, e.message
  rescue Whatsapp::RecordingBundleManifestValidator::Stale => e
    raise Stale, e.message
  end

  def stage_artifact(artifact)
    data = bundle_download do
      @client.download_recording_artifact(@scope[:session], artifact['id'], account_id: @scope[:account], call_id: @scope[:provider_call])
    end
    validate_artifact_data(data, artifact)
    suffix = artifact['format'] == 'rtp_framed_v1' ? 'rtp' : 'ogg'
    content_type = suffix == 'rtp' ? 'application/vnd.onelink.rtp-capture' : 'audio/ogg'
    metadata = { 'recording_artifact_id' => artifact['id'], 'recording_bundle_sha256' => @scope[:expected_sha],
                 'recording_artifact_sha256' => artifact['sha256'], 'recording_bundle_session_id' => @scope[:session] }
    blob = upload_blob(data, "call_#{@call.id}_#{artifact['id']}.#{suffix}", content_type, metadata)
    { artifact: artifact, blob: blob }
  end

  def validate_artifact_data(data, artifact)
    valid_data = data.bytesize == artifact['byte_size'] && Digest::SHA256.hexdigest(data) == artifact['sha256']
    raise Pending, 'Recording artifact integrity mismatch' unless valid_data

    Whatsapp::RecordingCaptureValidator.new(data: data, artifact: artifact).validate! if artifact['format'] == 'rtp_framed_v1'
  rescue Whatsapp::RecordingCaptureValidator::Invalid => e
    raise Invalid, e.message
  end

  def upload_blob(data, filename, content_type, metadata)
    blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new(data.b), filename: filename,
                                                  content_type: content_type, metadata: metadata, identify: false)
    @created_blobs << blob
    blob
  end

  def commit_import(staged, manifest_blob)
    @call.with_lock do
      @call.reload
      raise Stale, 'Recording scope changed during import' unless scope_snapshot == @scope
      return if completed?

      staged.each { |track| attach_track(track) }
      @call.recording_manifest.attach(manifest_blob)
      meta = (@call.meta || {}).deep_dup
      meta['recording_bundle']['completed_sha256'] = @scope[:expected_sha]
      meta['recording_bundle']['completed_at'] = Time.current.iso8601
      meta['recording_bundle']['artifact_count'] = staged.size
      meta['recording_bundle']['decoded_alignment'] = 'unknown'
      @call.update!(meta: meta)
    end
  end

  def attach_track(track)
    artifact, blob = track.values_at(:artifact, :blob)
    existing = @call.recording_tracks.blobs.find { |item| item.metadata['recording_artifact_id'] == artifact['id'] }
    if existing
      keys = %w[recording_artifact_id recording_bundle_sha256 recording_artifact_sha256 recording_bundle_session_id]
      same_bytes = existing.checksum == blob.checksum && existing.byte_size == blob.byte_size
      same_metadata = existing.metadata.slice(*keys) == blob.metadata.slice(*keys)
      raise Invalid, 'Existing recording artifact conflicts with import' unless same_bytes && same_metadata

      return
    end
    @call.recording_tracks.attach(blob)
  end

  def bundle_download
    yield
  rescue Whatsapp::MediaServerClient::SessionError => e
    raise Pending, 'Recording bundle temporarily unavailable' if [404, 409].include?(e.http_status) || e.http_status.to_i >= 500

    raise Invalid, 'Recording bundle download rejected'
  end
end
