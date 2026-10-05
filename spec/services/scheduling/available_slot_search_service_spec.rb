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

  it 'marks service-linked availability as customer-offer eligible' do
    payload = perform(resource_ids: [resource.id], service_id: service_record.id, limit: 1)

    expect(payload).to include(
      availability_scope: 'service_confirmed',
      requested_service_id: service_record.id,
      customer_offer_eligible: true
    )
    expect(payload[:service_match]).to include(
      confirmed: true,
      service_id: service_record.id,
      resource_id: resource.id,
      resource_ids: [resource.id],
      reason: 'local_configured'
    )
  end

  it 'keeps a MedElement price link unverified even when the provider returns fresh times' do
    resource.update!(custom_attributes: { 'medelement_specialist_code' => 'provider-123' })
    provider_result = Integrations::Medelement::ResourceAvailabilityService::Result.new(
      status: 'fresh', checked_at: Time.current, slots: [{ starts_at: from_time.iso8601, resource_id: resource.id }], reason: nil
    )
    allow(Integrations::Medelement::ResourceAvailabilityService).to receive(:new).and_return(
      instance_double(Integrations::Medelement::ResourceAvailabilityService, perform: provider_result)
    )

    payload = perform(resource_ids: [resource.id], service_id: service_record.id, limit: 1)

    expect(payload[:availability][:status]).to eq('fresh')
    expect(payload[:total_slots]).to eq(1)
    expect(payload[:slots].first[:service_eligibility_status]).to eq('price_link_unverified')
    expect(payload).to include(availability_scope: 'service_unconfirmed', service_link_status: 'price_link_unverified',
                               customer_offer_eligible: false)
    expect(payload[:service_match]).to include(confirmed: false, resource_ids: [], candidate_resource_ids: [resource.id])
  end

  it 'does not offer local-rule windows for a diagnostic provider resource without a specialist code' do
    resource.update!(custom_attributes: { 'medelement_cabinets' => [{ 'cabinetCode' => 'room-1' }] })
    expect(Integrations::Medelement::ResourceAvailabilityService).not_to receive(:new)

    payload = perform(resource_ids: [resource.id], service_id: service_record.id, limit: 1)

    expect(payload[:slots]).to be_empty
    expect(payload[:availability]).to include(
      status: 'degraded', resources: [include(status: 'unavailable', reason: 'provider_resource_route_unverified')]
    )
    expect(payload).to include(service_link_status: 'price_link_unverified', customer_offer_eligible: false)
  end

  it 'filters by service when no explicit specialists are provided' do
    payload = perform(service_id: service_record.id, limit: 1)

    expect(payload[:resources].pluck(:id)).to eq([resource.id])
    expect(payload[:resources].pluck(:id)).not_to include(other_resource.id, external_resource.id)
  end

  it 'marks service availability as unconfirmed when no specialist offers the service' do
    unsupported_service = create(:scheduling_service, account: account, name: 'Unsupported service', duration_min: 30)
    expect(Scheduling::ResourceAvailabilityQueryService).not_to receive(:new)

    payload = perform(service_id: unsupported_service.id, limit: 1)

    expect(payload).to include(
      availability_scope: 'service_unconfirmed',
      requested_service_id: unsupported_service.id,
      customer_offer_eligible: false
    )
    expect(payload[:service_match]).to include(confirmed: false, service_id: nil, resource_id: nil, resource_ids: [],
                                               candidate_resource_ids: [], reason: 'no_recorded_link')
    expect(payload[:slots]).to be_empty
  end

  it 'treats non-positive and blank service ids as an omitted filter' do
    [nil, 0, -1, ''].each do |service_id|
      payload = perform(service_id: service_id, limit: 1)

      expect(payload[:service]).to be_nil
      expect(payload[:resources].pluck(:id)).to contain_exactly(resource.id, other_resource.id)
      expect(payload).to include(
        availability_scope: 'generic',
        requested_service_id: nil,
        customer_offer_eligible: false
      )
      expect(payload[:service_match]).to include(confirmed: false, service_id: nil, resource_id: nil, resource_ids: [],
                                                 reason: 'not_requested')
    end
  end

  it 'raises when a requested specialist is outside the account or unavailable for scheduling' do
    expect do
      perform(resource_ids: [external_resource.id])
    end.to raise_error(ActiveRecord::RecordNotFound, "Scheduling resources not found: #{external_resource.id}")
  end

  it 'raises when the requested specialist cannot perform the requested service' do
    expect(Scheduling::ResourceAvailabilityQueryService).not_to receive(:new)

    expect do
      perform(resource_ids: [other_resource.id],
              service_id: service_record.id)
    end.to raise_error(ArgumentError, 'No recorded service-price link for requested resources; provider eligibility is unverified')
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
