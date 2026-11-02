require 'rails_helper'

RSpec.describe Accounts::AiDialogTimeline do
  it 'keeps the old three-tuple API and exact window shape' do
    at = Time.utc(2026, 11, 1)
    events = [[at, 20, false], [at + 1.minute, 1, false], [at + 25.hours, 1, false]]
    windows = described_class.new(events).windows

    expect(windows.pluck('replies_count')).to eq([20, 1, 1])
    expect(windows.first).to eq('started_at' => at.iso8601(6), 'last_reply_at' => at.iso8601(6), 'replies_count' => 20, 'legacy' => false)
    expect(windows.flat_map(&:keys)).not_to include('first_event_id')
  end

  it 'adds only the first source identity while retaining exact 24h/20 boundaries and legacy behaviour' do
    at = Time.utc(2026, 11, 1)
    events = [[at, 19, false, 101], [at + 1.minute, 1, false, 102], [at + 2.minutes, 1, false, 103],
              [at + 2.minutes + 24.hours, 1, false, 104]]
    expect(described_class.new(events).windows.pluck('first_event_id')).to eq([101, 103, 104])
    expect(described_class.new([[at, 2, true], [at + 1.minute, 1, false, 105]]).windows.first).to include('legacy' => true, 'replies_count' => 3)
  end
end
