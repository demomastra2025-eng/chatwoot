require 'rails_helper'

RSpec.describe Scheduling::AvailableSlotSearchService do
  let(:account) { create(:account) }
  let(:other_account) { create(:account) }
  let(:time_zone) { ActiveSupport::TimeZone['Asia/Almaty'] }
  let(:resource) { create(:scheduling_resource, account: account, name: 'Aigerim', timezone: 'Asia/Almaty', slot_duration_min: 30) }
  let(:other_resource) { create(:scheduling_resource, account: account, name: 'Dana', timezone: 'Asia/Almaty', slot_duration_min: 20) }
  let(:external_resource) { create(:scheduling_resource, account: other_account, name: 'External', timezone: 'Asia/Almaty') }
  let(:service_record) { create(:scheduling_service, account: account, name: 'Consultation', duration_min: 30) }
  let(:from_time) { time_zone.local(2026, 4, 20, 9, 0, 0) }
  let(:to_time) { time_zone.local(2026, 4, 20, 11, 0, 0) }

  before do
    create(:scheduling_work_rule, account: account, resource: resource, weekday: 1, start_minute: 9 * 60, end_minute: 11 * 60)
    create(:scheduling_work_rule, account: account, resource: other_resource, weekday: 1, start_minute: 9 * 60, end_minute: 11 * 60)
    create(:scheduling_work_rule, account: other_account, resource: external_resource, weekday: 1, start_minute: 9 * 60, end_minute: 11 * 60)
    create(:scheduling_service_price, account: account, service: service_record, resource: resource, active: true)
  end

  def perform(**attributes)
    described_class.new(account: account, from: from_time, to: to_time, **attributes).perform
  end

  it 'searches service-compatible slots with normalized resource metadata and global limiting' do
    payload = perform(resource_ids: [resource.id], service_id: service_record.id, limit: 2)

    expect(payload[:service]).to include(id: service_record.id, duration_min: 30)
    expect(payload[:duration_min]).to eq(30)
    expect(payload[:resources].pluck(:id)).to eq([resource.id])
    expect(payload[:slots].length).to eq(2)
    expect(payload[:slots].first).to include(
      resource_id: resource.id,
      resource_name: 'Aigerim',
      timezone: 'Asia/Almaty',
      starts_at: '2026-04-20T09:00:00+05:00',
      ends_at: '2026-04-20T09:30:00+05:00'
    )
    expect(payload[:total_slots]).to eq(2)
  end

  it 'filters by service when no explicit specialists are provided' do
    payload = perform(service_id: service_record.id, limit: 1)

    expect(payload[:resources].pluck(:id)).to eq([resource.id])
    expect(payload[:resources].pluck(:id)).not_to include(other_resource.id, external_resource.id)
  end

  it 'treats non-positive and blank service ids as an omitted filter' do
    [nil, 0, -1, ''].each do |service_id|
      payload = perform(service_id: service_id, limit: 1)

      expect(payload[:service]).to be_nil
      expect(payload[:resources].pluck(:id)).to contain_exactly(resource.id, other_resource.id)
    end
  end

  it 'raises when a requested specialist is outside the account or unavailable for scheduling' do
    expect do
      perform(resource_ids: [external_resource.id])
    end.to raise_error(ActiveRecord::RecordNotFound, "Specialists not found: #{external_resource.id}")
  end

  it 'raises when the requested specialist cannot perform the requested service' do
    expect do
      perform(resource_ids: [other_resource.id],
              service_id: service_record.id)
    end.to raise_error(ArgumentError, 'Service is not available for the requested specialists')
  end

  it 'rejects reversed ranges and oversized ranges' do
    expect do
      described_class.new(account: account, from: to_time, to: from_time).perform
    end.to raise_error(ArgumentError, 'to must be greater than from')

    expect do
      described_class.new(account: account, from: from_time, to: from_time + 32.days).perform
    end.to raise_error(ArgumentError, 'Date range must be 31 days or less')
  end
end
