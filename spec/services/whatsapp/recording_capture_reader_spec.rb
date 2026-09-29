require 'rails_helper'

RSpec.describe Whatsapp::RecordingCaptureReader do
  let(:packet) { synthetic_opus_packets(durations: [960]).first }

  def read_packets(packets, artifact_change: {}, data_change: nil)
    data = synthetic_capture(packets)
    artifact = synthetic_capture_artifact(packets, data: data).merge(artifact_change)
    data = data_change.call(data) if data_change
    described_class.new(io: StringIO.new(data), artifact: artifact, budget: Whatsapp::RecordingDecodeBudget.new).each.to_a
  end

  it 'parses the complete RTP header without including metadata or padding in native audio input' do
    parsed = read_packets([synthetic_full_rtp_header(packet)]).first
    expect(parsed.payload).to eq(packet.byteslice(12..))
    expect(parsed.ssrc).to eq(1234)
    expect(parsed.payload_type).to eq(111)
    expect(parsed.offset_ns).to eq(400_000_000)
  end

  it 'verifies actual streamed digest and byte size before source completion' do
    expect { read_packets([packet], artifact_change: { 'sha256' => 'a' * 64 }) }.to raise_error(Whatsapp::RecordingDecodeError, 'invalid_capture')
    expect { read_packets([packet], artifact_change: { 'byte_size' => 100_000 }) }.to raise_error(Whatsapp::RecordingDecodeError, 'invalid_capture')
  end

  it 'rejects incomplete magic, headers and packet frames' do
    [->(data) { data.byteslice(0, 6) }, ->(data) { data.byteslice(0, 12) }, ->(data) { data.byteslice(0, data.bytesize - 1) }].each do |change|
      expect { read_packets([packet], data_change: change) }.to raise_error(Whatsapp::RecordingDecodeError, 'invalid_capture')
    end
  end

  %w[version csrc extension padding_zero padding_large payload_empty].each do |kind|
    it "rejects malformed RTP #{kind} before native decoding" do
      broken = malformed_rtp(kind)
      expect { read_packets([broken]) }.to raise_error(Whatsapp::RecordingDecodeError, 'invalid_capture')
    end
  end

  def malformed_rtp(kind)
    header = packet.byteslice(0, 12).dup
    variants = { 'version' => [0x40, packet.byteslice(12..)], 'csrc' => [0x8f, 'x'],
                 'extension' => [0x90, "#{[0xbede, 100].pack('nn')}x".b], 'padding_zero' => [0xa0, "x\0".b],
                 'padding_large' => [0xa0, "x\xff".b], 'payload_empty' => [0x80, ''] }
    first, payload = variants.fetch(kind)
    header[0] = first.chr
    header + payload
  end

  it 'rejects foreign SSRC, incorrect packet count and altered observed offsets' do
    [{ 'ssrc' => 99 }, { 'packets' => 2 }, { 'first_offset_ns' => 0 }, { 'last_offset_ns' => 0 }].each do |change|
      expect { read_packets([packet], artifact_change: change) }.to raise_error(Whatsapp::RecordingDecodeError, 'invalid_capture')
    end
  end
end
