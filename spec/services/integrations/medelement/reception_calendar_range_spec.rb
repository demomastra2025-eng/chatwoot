require 'rails_helper'

RSpec.describe Integrations::Medelement::ReceptionCalendarRange do
  it 'uses local midnights and an exclusive end across both dates' do
    range = described_class.for(
      Time.iso8601('2026-09-07T18:30:00+05:00'), Time.iso8601('2026-09-08T00:30:00+05:00'),
      time_zone: 'Asia/Almaty'
    )

    expect(range.exclude_end?).to be(true)
    expect(range.begin.iso8601).to eq('2026-09-07T00:00:00+05:00')
    expect(range.end.iso8601).to eq('2026-09-09T00:00:00+05:00')
  end

  it 'uses the provider zone even when the application zone differs' do
    Time.use_zone('UTC') do
      range = described_class.for(
        Time.iso8601('2026-09-07T20:00:00Z'), Time.iso8601('2026-09-07T20:30:00Z'),
        time_zone: 'Asia/Almaty'
      )

      expect(range.begin.iso8601).to eq('2026-09-08T00:00:00+05:00')
      expect(range.end.iso8601).to eq('2026-09-09T00:00:00+05:00')
    end
  end
end
