require 'rails_helper'

RSpec.describe Whatsapp::RecordingDecodeBudget do
  it 'allows lowering ceilings and rejects raising or bypassing them' do
    expect { described_class.new(limits: { packets: 2 }) }.not_to raise_error
    [{ packets: 500_001 }, { packets: 0 }, { seconds: Float::INFINITY }, { unknown: 10 }].each do |limits|
      expect { described_class.new(limits: limits) }.to raise_error(ArgumentError)
    end
  end

  it 'checks a monotonic processing deadline explicitly' do
    budget = described_class.new
    allow(budget).to receive(:monotonic_now).and_return(Process.clock_gettime(Process::CLOCK_MONOTONIC) + 121)
    expect { budget.check! }.to raise_error(Whatsapp::RecordingDecodeError, 'time_limit')
  end

  it 'bounds epoch duration, chunks, gap ranges and mapping bytes' do
    budget = described_class.new(limits: { chunks: 1, gap_ranges: 1, mapping_bytes: 10 })
    budget.charge!(:chunks)
    budget.charge!(:gap_ranges)
    expect { budget.charge!(:chunks) }.to raise_error(Whatsapp::RecordingDecodeError, 'chunks_limit')
    expect { budget.charge!(:gap_ranges) }.to raise_error(Whatsapp::RecordingDecodeError, 'gap_ranges_limit')
    expect { budget.mapping!(11) }.to raise_error(Whatsapp::RecordingDecodeError, 'mapping_size_limit')
    expect { budget.epoch_samples!(48_000 * 3601) }.to raise_error(Whatsapp::RecordingDecodeError, 'epoch_duration_limit')
  end
end
