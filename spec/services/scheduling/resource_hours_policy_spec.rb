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

  it 'classifies the sync cache on the integration clock without limiting booking dates' do
    policy = described_class.new(resource: resource)
    last_day = zone.local(2026, 7, 18, 10)
    next_day = zone.local(2026, 7, 19, 10)

    expect(policy.cached_range?(from: last_day, to: last_day + 30.minutes)).to be(true)
    expect(policy.cached_range?(from: next_day, to: next_day + 30.minutes)).to be(false)
    expect(policy.clipped_range(from: next_day, to: next_day + 30.minutes)).to eq([next_day, next_day + 30.minutes])
  end

  it 'preserves requested dates across the sync boundary and for retrospective staff work' do
    policy = described_class.new(resource: resource)
    from = zone.local(2026, 7, 18, 9)
    to = zone.local(2026, 7, 20, 9)

    expect(policy.clipped_range(from: from, to: to)).to eq([from, to])
    earlier = zone.local(2026, 4, 18, 9)
    expect(policy.clipped_range(from: earlier, to: earlier + 1.hour)).to eq([earlier, earlier + 1.hour])
    expect(policy.cached_range?(from: earlier, to: earlier + 1.hour)).to be(false)
    expect(policy.clipped_range(from: from, to: from)).to be_nil
  end

  it 'does not impose a provider horizon on a local resource' do
    resource.update!(custom_attributes: {})
    policy = described_class.new(resource: resource)
    later = zone.local(2027, 4, 19, 10)

    expect(policy.clipped_range(from: later, to: later + 1.hour)).to eq([later, later + 1.hour])
    expect(policy.availability_options(nil)).to eq({})
  end
end
