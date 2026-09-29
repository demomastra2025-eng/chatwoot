require 'rails_helper'

RSpec.describe Whatsapp::RecordingEpochDecoder do
  let(:packets) { synthetic_opus_packets }

  it 'maps returned native samples to the shared observed anchor' do
    decoded = synthetic_epoch_decode(packets)
    expect(decoded[:summary]).to include('origin_offset_ns' => 400_000_000, 'end_offset_ns' => 800_000_000,
                                         'timeline_samples' => 19_200, 'decoded_samples' => 19_200)
    expect(decoded[:chunks].first).to include('sample_count' => 19_200, 'gap_ranges' => [])
    expect(decoded[:pcm].bytesize).to eq(19_200 * 4)
  end

  it 'decodes timestamp and sequence wrap to the same PCM as an ordinary stream' do
    regular = synthetic_epoch_decode(packets)
    wrapped = synthetic_epoch_decode(synthetic_opus_packets(timestamp: 0xffffff00, sequence: 65_530))
    expect(wrapped[:pcm]).to eq(regular[:pcm])
    expect(wrapped[:summary]['timeline_samples']).to eq(19_200)
  end

  it 'orders bounded reordering and removes identical duplicates without changing PCM' do
    regular = synthetic_epoch_decode(packets)
    reordered = packets[0, 2] + [packets[3], packets[2], packets[2]] + packets[4..]
    decoded = synthetic_epoch_decode(reordered)
    expect(decoded[:pcm]).to eq(regular[:pcm])
    expect(decoded[:summary]['duplicate_packets_dropped']).to eq(1)
    expect(decoded[:summary]['reordered_packets']).to eq(1)
  end

  it 'advances PLC state while storing silence and an explicit gap mask for lost audio' do
    remaining = packets[0, 5] + packets[6..]
    offsets = (0...20).reject { |index| index == 5 }.map { |index| 400_000_000 + (index * 20_000_000) }
    decoded = synthetic_epoch_decode(remaining, offsets: offsets)
    expect(decoded[:summary]).to include('timeline_samples' => 19_200, 'decoded_samples' => 18_240)
    expect(decoded[:chunks].first['gap_ranges']).to eq([{ 'start_sample' => 4800, 'end_sample' => 5760, 'reason' => 'unobserved_rtp_audio' }])
    expect(decoded[:pcm].byteslice(4800 * 4, 960 * 4)).to eq("\0".b * (960 * 4))
  end

  it 'preserves the RTP gap for DTX or silence without inventing speech' do
    changed = packets[6].dup
    changed[2, 2] = [packets[5].byteslice(2, 2).unpack1('n')].pack('n')
    input = packets[0, 5] + [changed]
    offsets = [400_000_000, 420_000_000, 440_000_000, 460_000_000, 480_000_000, 520_000_000]
    decoded = synthetic_epoch_decode(input, offsets: offsets)
    expect(decoded[:chunks].first['gap_ranges'].first).to include('start_sample' => 4800, 'end_sample' => 5760)
  end

  it 'retains native state when a WAV chunk boundary splits a packet' do
    regular = synthetic_epoch_decode(packets)
    split = synthetic_epoch_decode(packets, capacity: 1000)
    expect(split[:pcm]).to eq(regular[:pcm])
    expect(split[:chunks].sum { |chunk| chunk['sample_count'] }).to eq(19_200)
    expect(split[:chunks].map { |chunk| chunk['epoch_start_sample'] }).to eq((0...20).map { |index| index * 1000 })
  end

  it 'strips CSRC, extension and padding while preserving the Opus payload' do
    full = packets.map { |packet| synthetic_full_rtp_header(packet) }
    expect(synthetic_epoch_decode(full)[:pcm]).to eq(synthetic_epoch_decode(packets)[:pcm])
  end

  it 'uses actual durations when packet sizes vary' do
    durations = [120, 240, 480, 960, 1920, 2880]
    input = synthetic_opus_packets(durations: durations)
    cursor = 0
    offsets = durations.map do |samples|
      value = 400_000_000 + (cursor * 1_000_000_000 / 48_000)
      cursor += samples
      value
    end
    decoded = synthetic_epoch_decode(input, offsets: offsets)
    expect(decoded[:summary]['timeline_samples']).to eq(durations.sum)
    expect(decoded[:summary]['decoded_samples']).to eq(durations.sum)
  end

  it 'streams more than the reorder window with bounded packet retention' do
    input = synthetic_opus_packets(durations: Array.new(300, 960))
    decoded = synthetic_epoch_decode(input)
    expect(decoded[:summary]['timeline_samples']).to eq(288_000)
    expect(decoded[:summary]['decoded_packets']).to eq(300)
  end

  it 'keeps gap masks when lost audio crosses a WAV boundary' do
    remaining = packets[0, 5] + packets[6..]
    offsets = (0...20).reject { |index| index == 5 }.map { |index| 400_000_000 + (index * 20_000_000) }
    decoded = synthetic_epoch_decode(remaining, offsets: offsets, capacity: 5000)
    expect(decoded[:chunks][0]['gap_ranges'].first).to include('start_sample' => 4800, 'end_sample' => 5000)
    expect(decoded[:chunks][1]['gap_ranges'].first).to include('start_sample' => 0, 'end_sample' => 760)
  end

  it 'retains the original observed anchor when the initial packet is reordered' do
    decoded = synthetic_epoch_decode([packets[1], packets[0]] + packets[2..])
    expect(decoded[:summary]).to include('anchor_observed_offset_ns' => 400_000_000, 'anchor_rtp_timestamp' => 960,
                                         'origin_offset_ns' => 380_000_000, 'end_offset_ns' => 780_000_000)
  end

  it 'keeps a replayed same-SSRC sequence/timestamp restart ambiguous instead of removing a new epoch as duplicates' do
    expect { synthetic_epoch_decode(packets + packets) }.to raise_error(Whatsapp::RecordingDecodeError, 'ambiguous_packet_order')
  end

  it 'rejects packets arriving beyond the retained reorder history' do
    input = synthetic_opus_packets(durations: Array.new(300, 960))
    expect { synthetic_epoch_decode(input + [input.first]) }.to raise_error(Whatsapp::RecordingDecodeError, 'ambiguous_packet_order')
  end

  it 'rejects conflicting packets with the same sequence rather than picking one' do
    conflicting = packets[2].dup
    conflicting[-1] = (conflicting.getbyte(-1) ^ 1).chr
    expect { synthetic_epoch_decode(packets + [conflicting]) }.to raise_error(Whatsapp::RecordingDecodeError, 'ambiguous_packet_order')
  end

  it 'rejects unmarked clock reset without creating an enormous gap' do
    changed = packets[6].dup
    changed[4, 4] = [0].pack('N')
    expect { synthetic_epoch_decode(packets[0, 6] + [changed]) }.to raise_error(Whatsapp::RecordingDecodeError, 'overlapping_rtp_clock')
  end

  it 'enforces output and packet ceilings before successful completion' do
    expect { synthetic_epoch_decode(packets, limits: { output_bytes: 100 }) }.to raise_error(Whatsapp::RecordingDecodeError, 'output_bytes_limit')
    expect { synthetic_epoch_decode(packets, limits: { packets: 5 }) }.to raise_error(Whatsapp::RecordingDecodeError, 'packets_limit')
  end

  it 'rejects a large RTP jump inconsistent with observed time' do
    changed = packets[1].dup
    changed[4, 4] = [48_000 * 60].pack('N')
    expect { synthetic_epoch_decode([packets[0], changed]) }.to raise_error(Whatsapp::RecordingDecodeError, 'ambiguous_observed_clock')
  end
end
