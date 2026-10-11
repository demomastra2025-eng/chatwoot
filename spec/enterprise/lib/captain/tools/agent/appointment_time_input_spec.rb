require 'rails_helper'

RSpec.describe Captain::Tools::Agent::AppointmentTimeInput do
  let(:zone) { ActiveSupport::TimeZone['Asia/Almaty'] }

  def parse(value, timezone = zone)
    described_class.parse(value, timezone: timezone, field_name: 'starts_at')
  end

  it 'resolves the requested 14:00 calendar clock once in the specialist timezone' do
    expect(parse('2026-10-15T14:00').utc).to eq(Time.utc(2026, 10, 15, 9))
  end

  it 'preserves exact instants returned by slots with either Z or an offset' do
    expect(parse('2026-10-15T09:00:00Z')).to eq(parse('2026-10-15T14:00:00+05:00'))
    expect(parse('2026-10-15T09:00:00Z').iso8601).to eq('2026-10-15T09:00:00Z')
    expect(parse('2026-10-15T14:00:00+05:00').iso8601).to eq('2026-10-15T14:00:00+05:00')
  end

  it 'uses a specialist timezone ahead of the account default' do
    selected = described_class.timezone(resource_timezone: 'Asia/Kathmandu', account_timezone: 'UTC')
    expect(parse('2026-10-15T14:00', selected).utc).to eq(Time.utc(2026, 10, 15, 8, 15))
  end

  it 'uses the account timezone if the resource has no timezone' do
    selected = described_class.timezone(resource_timezone: nil, account_timezone: 'Asia/Almaty')
    expect(parse('2026-10-15T14:00', selected).utc).to eq(Time.utc(2026, 10, 15, 9))
  end

  it 'rejects incomplete or impossible local dates before any mutation' do
    %w[2026-10-15 2026-02-30T14:00 2026-10-15T24:00 tomorrow].each do |value|
      expect { parse(value) }.to raise_error(Scheduling::Error) { |error|
        expect(error.code).to eq('INVALID_DATE')
        expect(error.details).to include(mutation_executed: false)
      }
    end
  end

  it 'rejects an ambiguous daylight-saving clock instead of selecting an hour' do
    expect { parse('2026-11-01T01:30', ActiveSupport::TimeZone['America/New_York']) }.to raise_error(Scheduling::Error)
  end

  it 'rejects a nonexistent daylight-saving clock instead of shifting it' do
    expect { parse('2026-03-08T02:30', ActiveSupport::TimeZone['America/New_York']) }.to raise_error(Scheduling::Error)
  end

  it 'accepts an exact offset from a returned slot during a repeated clock hour' do
    expect(parse('2026-11-01T01:30:00-05:00', ActiveSupport::TimeZone['America/New_York']).utc).to eq(Time.utc(2026, 11, 1, 6, 30))
  end
end
