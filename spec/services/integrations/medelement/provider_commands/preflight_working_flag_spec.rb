require 'rails_helper'

RSpec.describe Integrations::Medelement::ProviderCommands::Preflight do
  it 'uses the same working flag values as slot search' do
    preflight = described_class.allocate
    interval = [Time.zone.parse('2026-04-20 09:00:00'), Time.zone.parse('2026-04-20 10:00:00')]
    allow(preflight).to receive(:parsed_interval).and_return(interval)
    timetable = {
      '20.04.2026' => {
        'timetable' => [
          { 'working' => 1 },
          { 'working' => 'true' },
          { 'working' => false }
        ]
      }
    }

    expect(preflight.send(:working_intervals, timetable)).to eq([interval, interval])
  end
end
