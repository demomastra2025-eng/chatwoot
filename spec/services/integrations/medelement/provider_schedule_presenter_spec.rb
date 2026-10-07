require 'rails_helper'

RSpec.describe Integrations::Medelement::ProviderSchedulePresenter do
  let(:account) { create(:account) }
  let(:hook) { create(:integrations_hook, :medelement, account: account) }
  let(:now) { Time.zone.parse('2026-10-07 09:00:00 +0500') }
  let(:date) { now.in_time_zone('Asia/Almaty').to_date }
  let(:resource) do
    create(:scheduling_resource, account: account,
                                 custom_attributes: { 'medelement_specialist_code' => 'doctor-1' })
  end

  before { account.enable_features!('scheduling') }

  it 'exposes real hours and a difference flag only on linked doctor payloads' do
    hook
    create(:scheduling_work_rule, account: account, resource: resource, weekday: date.wday,
                                  start_minute: 540, end_minute: 1080)
    Integrations::Medelement::ScheduleDay.create!(
      account: account, hook: hook, resource: resource, specialist_code: 'doctor-1', date: date,
      windows: [{ start_minute: 600, end_minute: 720 }], status: 'confirmed', source_checked_at: now
    )
    local = create(:scheduling_resource, account: account)

    presented = described_class.new(account: account, resources: [resource, local], now: now).payloads
    payload = Scheduling::PayloadBuilder.resource(resource, provider_schedule: presented.fetch(resource))

    expect(payload[:provider_schedule]).to include(checked_at: now.iso8601, horizon_days: 14, differs_from_template: true)
    expect(payload.dig(:provider_schedule, :days).first).to eq(
      date: date.iso8601, windows: [{ start: '10:00', end: '12:00' }], status: 'confirmed'
    )
    expect(payload.dig(:provider_schedule, :days).size).to eq(14)
    expect(presented).not_to have_key(local)
    expect(Scheduling::PayloadBuilder.resource(local)).not_to have_key(:provider_schedule)
  end

  it 'keeps a linked doctor visible as not loaded before the first snapshot' do
    hook

    payload = described_class.new(account: account, resources: [resource], now: now).payloads.fetch(resource)

    expect(payload).to include(checked_at: nil, horizon_days: 14, differs_from_template: false)
    expect(payload[:days].first).to eq(date: date.iso8601, windows: [], status: 'unverified')
  end
end
