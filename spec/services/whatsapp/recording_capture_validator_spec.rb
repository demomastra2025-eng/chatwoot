require 'rails_helper'

RSpec.describe Whatsapp::RecordingCaptureValidator do
  let(:packet) { [0x80, 111, 1, 960, 1234].pack('CCnNN') + "\xf8\xff\xfe".b }
  let(:artifact) { { 'ssrc' => 1234, 'packets' => 1, 'first_offset_ns' => 400, 'last_offset_ns' => 400 } }

  def validate_packet(data = packet)
    framed = "OLRTP1\n".b + [400, data.bytesize].pack('Q>L>') + data
    described_class.new(data: framed, artifact: artifact).validate!
  end

  it 'accepts an exact RTP payload with CSRCs, extension and padding' do
    header = [0xb2, 111, 1, 960, 1234, 5678, 9012].pack('CCnNNNN')
    extension = [0xbede, 1].pack('nn') + "\x10\x01\x00\x00".b
    padded = header + extension + "\xf8\xff\xfe\x00\x00\x00\x04".b

    expect { validate_packet(padded) }.not_to raise_error
  end

  it 'accepts a plain synthetic packet without decoded timing claims' do
    expect { validate_packet }.not_to raise_error
  end

  it 'rejects an RTP version mismatch' do
    packet.setbyte(0, 0x40)

    expect { validate_packet }.to raise_error(described_class::Invalid)
  end

  it 'rejects an SSRC inconsistent with the source manifest' do
    artifact['ssrc'] = 4321

    expect { validate_packet }.to raise_error(described_class::Invalid)
  end

  it 'rejects a truncated CSRC list' do
    packet.setbyte(0, 0x82)

    expect { validate_packet }.to raise_error(described_class::Invalid)
  end

  it 'rejects a truncated RTP extension' do
    packet.setbyte(0, 0x90)
    data = packet.byteslice(0, 12) + [0xbede, 5].pack('nn') + packet.byteslice(12, 3)

    expect { validate_packet(data) }.to raise_error(described_class::Invalid)
  end

  it 'rejects zero or excessive RTP padding' do
    packet.setbyte(0, 0xa0)
    packet.setbyte(-1, 0)
    expect { validate_packet }.to raise_error(described_class::Invalid)

    packet.setbyte(-1, 16)
    expect { validate_packet }.to raise_error(described_class::Invalid)
  end

  it 'rejects a frame count or monotonic offset that differs from the manifest' do
    artifact['packets'] = 2
    expect { validate_packet }.to raise_error(described_class::Invalid)

    artifact['packets'] = 1
    artifact['first_offset_ns'] = 300
    expect { validate_packet }.to raise_error(described_class::Invalid)
  end
end
