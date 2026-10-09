require 'rails_helper'

RSpec.describe Scheduling::ResourceHoursPolicy do
  include ActiveSupport::Testing::TimeHelpers

  let(:account) { create(:account) }
  let(:zone) { ActiveSupport::TimeZone['Asia/Almaty'] }
  let(:resource) do
    create(:scheduling_resource, account: account, timezone: 'America/New_York',
                                 custom_attributes: { 'medelement_specialist_code' => 'doctor-1' })
  end

  around { |example| travel_to(Time.utc(2026, 4, 19, 20)) { example.run } }

  before do
    account.enable_features!('scheduling')
    create(:integrations_hook, :medelement, account: account, settings: { 'timezone' => 'Asia/Almaty' })
  end

  it 'uses the integration date even when the resource has another time zone' do
    policy = described_class.new(resource: resource)
    last_day = zone.local(2026, 7, 18, 10)
    next_day = zone.local(2026, 7, 19, 10)

    expect(policy.last_date).to eq(Date.new(2026, 7, 18))
    expect { policy.validate_booking!(starts_at: last_day, ends_at: last_day + 30.minutes) }.not_to raise_error
    expect { policy.validate_booking!(starts_at: next_day, ends_at: next_day + 30.minutes) }
      .to raise_error(Scheduling::Error) { |error|
        expect(error.code).to eq('MEDELEMENT_HORIZON_EXCEEDED')
        expect(error.status).to eq(422)
        expect(error.message).to eq('График врача открыт до 18.07.2026. Запись на более позднюю дату пока невозможна.')
      }
  end

  it 'clips searches to the first 90 integration dates' do
    policy = described_class.new(resource: resource)
    from = zone.local(2026, 7, 18, 9)
    to = zone.local(2026, 7, 20, 9)

    expect(policy.clipped_range(from: from, to: to)).to eq([from, zone.local(2026, 7, 19)])
    expect(policy.clipped_range(from: to, to: to + 1.day)).to be_nil
  end

  it 'does not impose a provider horizon on a local resource' do
    resource.update!(custom_attributes: {})
    policy = described_class.new(resource: resource)
    later = zone.local(2027, 4, 19, 10)

    expect(policy.clipped_range(from: later, to: later + 1.hour)).to eq([later, later + 1.hour])
    expect { policy.validate_booking!(starts_at: later, ends_at: later + 30.minutes) }.not_to raise_error
  end
end
