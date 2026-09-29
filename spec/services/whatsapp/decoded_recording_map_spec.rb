require 'rails_helper'

RSpec.describe Whatsapp::DecodedRecordingMap do
  let(:mapping) do
    { 'version' => 1, 'state' => 'completed', 'decoder_contract' => Whatsapp::RecordingDecodeBudget::CONTRACT, 'sample_rate' => 48_000,
      'epochs' => [{ 'id' => 'epoch_000001', 'origin_offset_ns' => 400_000_000 }],
      'chunks' => [{ 'id' => 'chunk_000001', 'epoch_id' => 'epoch_000001', 'epoch_start_sample' => 1000, 'sample_count' => 960,
                     'gap_ranges' => [{ 'start_sample' => 120, 'end_sample' => 240 }] }] }
  end

  it 'maps samples with one integer calculation across a chunk boundary' do
    map = described_class.new(mapping: mapping)
    expect(map.range_ns(chunk_id: 'chunk_000001', start_sample: 0, end_sample: 120)).to eq(
      [400_000_000 + (1000 * 1_000_000_000 / 48_000), 400_000_000 + (1120 * 1_000_000_000 / 48_000)]
    )
  end

  it 'rejects speech intervals that touch captured gaps' do
    map = described_class.new(mapping: mapping)
    expect { map.range_ns(chunk_id: 'chunk_000001', start_sample: 100, end_sample: 200) }.to raise_error(
      Whatsapp::RecordingDecodeError, 'decoded_range_intersects_gap'
    )
  end

  it 'rejects unknown chunks, noninteger samples and intervals outside the chunk' do
    map = described_class.new(mapping: mapping)
    [{ chunk_id: 'foreign', start_sample: 0, end_sample: 1 }, { chunk_id: 'chunk_000001', start_sample: Float::NAN, end_sample: 1 },
     { chunk_id: 'chunk_000001', start_sample: 0, end_sample: 961 }].each do |arguments|
      expect { map.range_ns(**arguments) }.to raise_error(Whatsapp::RecordingDecodeError, 'invalid_decoded_range')
    end
  end

  it 'rejects a mapping produced by another decoder contract' do
    mapping['decoder_contract'] = 'unknown'
    expect { described_class.new(mapping: mapping) }.to raise_error(Whatsapp::RecordingDecodeError, 'unsupported_decoded_mapping')
  end
end
