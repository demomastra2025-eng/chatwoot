require 'rails_helper'

RSpec.describe Whatsapp::NativeOpusDecoder do
  it 'decodes native mono and stereo packets using returned per-channel samples and explicit output channels' do
    [1, 2].each do |channels|
      packet = synthetic_opus_packets(durations: [960], channels: channels).first
      decoder = described_class.new
      frame = decoder.decode(packet.byteslice(12..))
      expect(frame.samples).to eq(960)
      expect(frame.packet_channels).to eq(channels)
      expect(frame.pcm.bytesize).to eq(960 * 2 * 2)
      expect(frame.pcm.unpack('s<*')).to include(a_value > 0)
      expect(decoder.version).to start_with('libopus')
    ensure
      decoder&.close
    end
  end

  it 'uses actual native samples for variable legal Opus packet durations' do
    durations = [120, 240, 480, 960, 1920, 2880]
    packets = synthetic_opus_packets(durations: durations)
    decoder = described_class.new
    frames = packets.map { |packet| decoder.decode(packet.byteslice(12..)) }
    expect(frames.map(&:samples)).to eq(durations)
    expect(frames.map { |frame| frame.pcm.bytesize }).to eq(durations.map { |samples| samples * 4 })
  ensure
    decoder&.close
  end

  it 'decodes a valid 120ms packet into the exact maximum bounded output buffer' do
    payload = "\xfb\x06".b + ("\xff\xfe".b * 6)
    decoder = described_class.new
    frame = decoder.decode(payload)
    expect(frame.samples).to eq(5760)
    expect(frame.pcm.bytesize).to eq(23_040)
    expect { decoder.decode("\xfb\x07".b + ("\xff\xfe".b * 7)) }.to raise_error(described_class::InvalidPacket)
  ensure
    decoder&.close
  end

  it 'rejects unsafe payload lengths before any native packet parsing' do
    library = described_class::Library.new
    decoder = described_class.new(library: library)
    expect(library).not_to receive(:call).with(:samples, anything, anything, anything)
    [nil, '', 'x' * (described_class::MAX_PACKET_BYTES + 1), 12].each do |payload|
      expect { decoder.decode(payload) }.to raise_error(described_class::InvalidPacket, 'invalid_opus_payload_size')
    end
  ensure
    decoder&.close
  end

  it 'rejects corrupt or excessive-frame native input without exposing an output buffer' do
    decoder = described_class.new
    ["\xff".b, "\xff\xff".b].each do |payload|
      expect { decoder.decode(payload) }.to raise_error(described_class::InvalidPacket)
    end
  ensure
    decoder&.close
  end

  it 'advances native concealment for an exact missing duration and rejects invalid PLC lengths' do
    decoder = described_class.new
    expect(decoder.conceal(960)).to eq(960)
    [0, 119, 121, 5761, nil].each do |samples|
      expect { decoder.conceal(samples) }.to raise_error(described_class::InvalidPacket, 'invalid_concealment_size')
    end
  ensure
    decoder&.close
  end

  it 'destroys the native decoder exactly once and explicitly frees owned buffers after failure' do
    library = described_class::Library.new
    decoder = described_class.new(library: library)
    input = decoder.instance_variable_get(:@input)
    output = decoder.instance_variable_get(:@pcm)
    allow(library).to receive(:call).and_call_original
    expect(library).to receive(:call).with(:destroy, kind_of(Fiddle::Pointer)).once.and_call_original
    expect { decoder.decode("\xff".b) }.to raise_error(described_class::InvalidPacket)
    2.times { decoder.close }
    expect(input).to be_freed
    expect(output).to be_freed
    expect { decoder.decode('x') }.to raise_error(described_class::InvalidPacket, 'opus_decoder_closed')
  end

  it 'reports unavailable libraries explicitly without needing native calls during class loading' do
    expect { described_class::Library.new(paths: ['/synthetic-missing/libopus.so']) }.to raise_error(described_class::Unavailable)
    expect(described_class).to be_a(Class)
  end
end
