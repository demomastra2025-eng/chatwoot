require 'rails_helper'

RSpec.describe Whatsapp::RecordingBundleManifestValidator do
  let(:contract) { JSON.parse(Rails.root.join('enterprise/media-server/internal/media/testdata/recording_bundle_limits.json').read) }
  let(:manifest) do
    {
      'version' => contract.fetch('version'), 'session_id' => 'session_test', 'account_id' => '42', 'call_id' => 'call_test',
      'state' => 'final', 'clock_basis' => 'recorder_observed_monotonic', 'decoded_alignment' => 'unknown',
      'origin' => '2023-11-14T22:13:20Z', 'end_offset_ns' => 1_000_000_000, 'artifacts' => []
    }
  end

  def legacy_artifact(side, size)
    {
      'id' => "#{side}_legacy", 'format' => 'legacy_side_ogg', 'side' => side,
      'continuity_reason' => 'legacy_timing_unknown', 'byte_size' => size, 'sha256' => 'a' * 64
    }
  end

  def capture_artifact(size)
    {
      'id' => 'track_000001', 'format' => 'rtp_framed_v1', 'side' => 'customer', 'source_kind' => 'meta',
      'generation' => 1, 'codec' => 'audio/opus', 'clock_rate' => 48_000, 'ssrc' => 1, 'packets' => 1,
      'rtp_ticks' => 0, 'unordered_packets' => 0, 'timestamp_wraps' => 0, 'first_rtp_timestamp' => 960,
      'last_rtp_timestamp' => 960, 'first_offset_ns' => 0, 'last_offset_ns' => 0, 'byte_size' => size, 'sha256' => 'b' * 64
    }
  end

  def validate_manifest
    data = JSON.generate(manifest)
    scope = { session: 'session_test', account: '42', provider_call: 'call_test', expected_sha: Digest::SHA256.hexdigest(data) }
    described_class.new(scope: scope).validate!(data)
  end

  it 'shares the exact version and production byte bounds with the Go producer' do
    expect(contract).to eq(
      'version' => 1,
      'max_artifact_bytes' => described_class::MAX_ARTIFACT_BYTES,
      'max_bundle_bytes' => described_class::MAX_BUNDLE_BYTES
    )
  end

  it 'accepts two legacy sides exactly at the per-artifact and aggregate bounds without allocating recordings' do
    size = contract.fetch('max_artifact_bytes')
    manifest['artifacts'] = [legacy_artifact('customer', size), legacy_artifact('agent', size)]

    expect { validate_manifest }.not_to raise_error
  end

  it 'rejects a legacy artifact one byte over the shared per-artifact bound' do
    manifest['artifacts'] = [legacy_artifact('customer', contract.fetch('max_artifact_bytes') + 1)]

    expect { validate_manifest }.to raise_error(described_class::Invalid, 'Invalid artifact integrity fields')
  end

  it 'accepts captures and both legacy sides exactly at the shared aggregate bound' do
    size = contract.fetch('max_artifact_bytes')
    manifest['artifacts'] = [capture_artifact(34), legacy_artifact('customer', size), legacy_artifact('agent', size - 34)]

    expect { validate_manifest }.not_to raise_error
  end

  it 'rejects aggregate overflow even when each capture and legacy side fits its individual bound' do
    size = contract.fetch('max_artifact_bytes')
    manifest['artifacts'] = [capture_artifact(34), legacy_artifact('customer', size), legacy_artifact('agent', size - 33)]

    expect { validate_manifest }.to raise_error(described_class::Invalid, 'Recording bundle exceeds size limit')
  end
end
