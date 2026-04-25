require 'rails_helper'

RSpec.describe Scheduling::ResourceAvailabilityQueryService do
  let(:account) { create(:account) }
  let(:time_zone) { ActiveSupport::TimeZone['Asia/Almaty'] }
  let(:resource) { create(:scheduling_resource, account: account, name: 'Aigerim', timezone: 'Asia/Almaty', slot_duration_min: 30) }
  let(:service_record) { create(:scheduling_service, account: account, name: 'Consultation', duration_min: 30) }
  let(:from_time) { time_zone.local(2026, 4, 20, 9, 0, 0) }
  let(:to_time) { time_zone.local(2026, 4, 20, 11, 0, 0) }

  before do
    create(:scheduling_work_rule, account: account, resource: resource, weekday: 1, start_minute: 9 * 60, end_minute: 11 * 60)
  end

  def perform(**attributes)
    described_class.new(resource: resource, from: from_time, to: to_time, **attributes).perform
  end

  it 'returns service-derived duration and excludes appointments, breaks, and time-offs from slots' do
    create(:scheduling_service_price, account: account, service: service_record, resource: resource, active: true)
    create(:scheduling_break_rule, account: account, resource: resource, weekday: 1, start_minute: 10 * 60, end_minute: (10 * 60) + 15)
    create(:scheduling_time_off, account: account, resource: resource, starts_at: time_zone.local(2026, 4, 20, 10, 30),
                                 ends_at: time_zone.local(2026, 4, 20, 11, 0))
    create(:scheduling_appointment, account: account, resource: resource, service: service_record, starts_at: time_zone.local(2026, 4, 20, 9, 30),
                                    ends_at: time_zone.local(2026, 4, 20, 10, 0), duration_min: 30)

    payload = perform(service: service_record, limit: 10)

    expect(payload[:duration_min]).to eq(30)
    expect(payload[:timezone]).to eq('Asia/Almaty')
    expect(payload[:slots]).to eq([
                                    {
                                      resource_id: resource.id,
                                      starts_at: '2026-04-20T09:00:00+05:00',
                                      ends_at: '2026-04-20T09:30:00+05:00',
                                      duration_min: 30,
                                      status: 'available'
                                    }
                                  ])
    expect(payload[:total_slots]).to eq(1)
  end

  it 'uses explicit duration when no service is provided and falls back to resource duration otherwise' do
    explicit_payload = perform(duration_min: 20, limit: 1)
    fallback_payload = perform(limit: 1)

    expect(explicit_payload[:duration_min]).to eq(20)
    expect(explicit_payload[:slots].first[:ends_at]).to eq('2026-04-20T09:20:00+05:00')
    expect(fallback_payload[:duration_min]).to eq(30)
    expect(fallback_payload[:slots].first[:ends_at]).to eq('2026-04-20T09:30:00+05:00')
  end

  it 'caps slot payload size by limit' do
    payload = perform(duration_min: 5, limit: 3)

    expect(payload[:slots].length).to eq(3)
    expect(payload[:total_slots]).to eq(3)
  end

  it 'rejects reversed ranges at the domain layer' do
    expect do
      described_class.new(resource: resource, from: to_time, to: from_time).perform
    end.to raise_error(ArgumentError, 'to must be greater than from')
  end

  it 'rejects ranges larger than the scheduling safety window at the domain layer' do
    expect do
      described_class.new(resource: resource, from: from_time, to: from_time + 32.days).perform
    end.to raise_error(ArgumentError, 'Date range must be 31 days or less')
  end
end
