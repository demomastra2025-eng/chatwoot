require 'digest'
require 'json'

class Whatsapp::RecordingBundleManifestValidator
  class Pending < StandardError; end
  class Invalid < StandardError; end
  class Stale < StandardError; end

  MAX_MANIFEST_BYTES = 1.megabyte
  MAX_ARTIFACT_BYTES = 128.megabytes
  MAX_BUNDLE_BYTES = 256.megabytes
  SHA_PATTERN = /\A[0-9a-f]{64}\z/
  SOURCE_SIDES = { 'meta' => 'customer', 'browser' => 'agent', 'runtime' => 'agent' }.freeze

  def initialize(scope:)
    @scope = scope
  end

  def validate!(data)
    raise Invalid, 'Manifest exceeds size limit' if data.bytesize > MAX_MANIFEST_BYTES
    raise Pending, 'Manifest digest is not ready' unless Digest::SHA256.hexdigest(data) == @scope[:expected_sha]

    manifest = JSON.parse(data)
    validate_manifest_header(manifest)
    validate_manifest_clock(manifest)
    validate_artifact_list(manifest)
    manifest
  rescue JSON::ParserError, KeyError, ArgumentError, TypeError => e
    raise Invalid, "Invalid recording manifest: #{e.class.name}"
  end

  private

  def validate_manifest_header(manifest)
    raise Invalid, 'Unsupported recording manifest version' unless manifest.is_a?(Hash) && manifest['version'] == 1
    raise Stale, 'Recording manifest scope mismatch' unless manifest_scope_matches?(manifest)
    raise Pending, 'Recording manifest is not final' unless manifest['state'] == 'final' && manifest['error_code'].blank?
  end

  def manifest_scope_matches?(manifest)
    manifest.values_at('session_id', 'account_id', 'call_id') == @scope.values_at(:session, :account, :provider_call)
  end

  def validate_manifest_clock(manifest)
    valid_clock = manifest['clock_basis'] == 'recorder_observed_monotonic' && manifest['decoded_alignment'] == 'unknown'
    raise Invalid, 'Unsupported recording clock' unless valid_clock
    raise Invalid, 'Invalid recording end offset' unless nonnegative_integer?(manifest['end_offset_ns'])
    raise Invalid, 'Invalid recording origin' unless manifest['origin'].is_a?(String) && manifest['origin'].size <= 64

    Time.iso8601(manifest['origin'])
  end

  def validate_artifact_list(manifest)
    artifacts = manifest['artifacts']
    raise Invalid, 'Invalid recording artifacts' unless valid_artifact_list?(artifacts)
    raise Invalid, 'Duplicate recording artifact ID' unless artifacts.pluck('id').uniq.size == artifacts.size

    artifacts.each { |artifact| validate_artifact(artifact, manifest['end_offset_ns']) }
    raise Invalid, 'Recording bundle exceeds size limit' if artifacts.sum { |artifact| artifact['byte_size'] } > MAX_BUNDLE_BYTES
  end

  def valid_artifact_list?(artifacts)
    artifacts.is_a?(Array) && artifacts.size <= 1024 && artifacts.all?(Hash)
  end

  def validate_artifact(artifact, end_offset)
    validate_artifact_integrity(artifact)
    raise Invalid, 'Invalid artifact side' unless %w[customer agent].include?(artifact['side'])

    case artifact['format']
    when 'rtp_framed_v1'
      validate_capture_artifact(artifact, end_offset)
    when 'legacy_side_ogg'
      valid_legacy = artifact['id'] == "#{artifact['side']}_legacy" && artifact['continuity_reason'] == 'legacy_timing_unknown'
      raise Invalid, 'Invalid legacy recording artifact' unless valid_legacy
    else
      raise Invalid, 'Unsupported recording artifact format'
    end
  end

  def validate_artifact_integrity(artifact)
    valid_size = artifact['byte_size'].is_a?(Integer) && artifact['byte_size'].between?(1, MAX_ARTIFACT_BYTES)
    raise Invalid, 'Invalid artifact integrity fields' unless valid_size && SHA_PATTERN.match?(artifact['sha256'].to_s)
  end

  def validate_capture_artifact(artifact, end_offset)
    raise Invalid, 'Invalid capture artifact ID' unless artifact['id'].to_s.match?(/\Atrack_\d{6}\z/)

    validate_capture_provenance(artifact)
    validate_capture_counters(artifact)
    validate_capture_offsets(artifact, end_offset)
  end

  def validate_capture_provenance(artifact)
    valid_kind = %w[meta browser runtime].include?(artifact['source_kind'])
    valid_codec = artifact['codec'].is_a?(String) && artifact['codec'].size <= 100
    raise Invalid, 'Invalid capture provenance' unless valid_kind && valid_codec
    raise Invalid, 'Invalid capture generation' unless artifact['generation'].is_a?(Integer) && artifact['generation'].positive?
    raise Invalid, 'Capture role does not match source' unless SOURCE_SIDES[artifact['source_kind']] == artifact['side']
  end

  def validate_capture_counters(artifact)
    fields = %w[clock_rate ssrc rtp_ticks packets unordered_packets timestamp_wraps]
    raise Invalid, 'Invalid capture counters' unless fields.all? { |key| nonnegative_integer?(artifact[key]) }
    raise Invalid, 'Empty capture artifact' unless artifact['packets'].positive?
    raise Invalid, 'Invalid unordered packet count' if artifact['unordered_packets'] > artifact['packets']

    validate_capture_clock_fields(artifact)
  end

  def validate_capture_clock_fields(artifact)
    raise Invalid, 'Invalid capture clock rate' unless artifact['clock_rate'].between?(0, 192_000)

    fields = %w[ssrc first_rtp_timestamp last_rtp_timestamp]
    valid_fields = fields.all? { |key| artifact[key].is_a?(Integer) && artifact[key].between?(0, (1 << 32) - 1) }
    raise Invalid, 'Invalid RTP clock fields' unless valid_fields
  end

  def validate_capture_offsets(artifact, end_offset)
    first, last = artifact.values_at('first_offset_ns', 'last_offset_ns')
    valid_offsets = [first, last].all? { |offset| nonnegative_integer?(offset) }
    raise Invalid, 'Invalid capture offsets' unless valid_offsets && first <= last && last <= end_offset
  end

  def nonnegative_integer?(value)
    value.is_a?(Integer) && value.between?(0, (1 << 63) - 1)
  end
end
