require 'rails_helper'

# Labels of the slot answer (source, service link status, eligibility). The MedElement contract specs that pin the
# basic behaviour of this service live in available_slot_search_service_spec.rb and are intentionally left untouched.
RSpec.describe Scheduling::AvailableSlotSearchService do
  let(:account) { create(:account) }
  let(:other_account) { create(:account) }
  let(:time_zone) { ActiveSupport::TimeZone['Asia/Almaty'] }
  let(:from_time) { time_zone.local(2026, 4, 20, 9, 0, 0) }
  let(:to_time) { time_zone.local(2026, 4, 20, 11, 0, 0) }
  let(:service_record) { create(:scheduling_service, account: account, name: 'Consultation', duration_min: 30) }
  let(:local_resource) { create_resource('Local') }
  let(:provider_resource) { create_resource('Provider', custom_attributes: { 'medelement_specialist_code' => 'provider-1' }) }

  def create_resource(name, **attributes)
    create(:scheduling_resource, account: account, name: name, timezone: 'Asia/Almaty', slot_duration_min: 30, **attributes).tap do |record|
      create(:scheduling_work_rule, account: account, resource: record, weekday: 1, start_minute: 9 * 60, end_minute: 11 * 60)
    end
  end

  def link(resource, service: service_record, active: true)
    create(:scheduling_service_price, account: account, service: service, resource: resource, active: active)
  end

  def perform(**attributes)
    described_class.new(account: account, from: from_time, to: to_time, **attributes).perform
  end

  def provider_result(status:, slots: [], reason: nil)
    Integrations::Medelement::ResourceAvailabilityService::Result.new(status: status, checked_at: Time.current, slots: slots, reason: reason)
  end

  def stub_provider(results_by_resource_id)
    allow(Integrations::Medelement::ResourceAvailabilityService).to receive(:new) do |resource:, **|
      instance_double(Integrations::Medelement::ResourceAvailabilityService, perform: results_by_resource_id.fetch(resource.id))
    end
  end

  def provider_slot(resource)
    { starts_at: from_time.iso8601, ends_at: (from_time + 30.minutes).iso8601, resource_id: resource.id }
  end

  describe 'local mode' do
    before { link(local_resource) }

    it 'labels the answer as local, configured and confirmed, and counts only the returned slots' do
      payload = perform(resource_ids: [local_resource.id], service_id: service_record.id, limit: 1)

      expect(payload).to include(
        total_slots: 1, slot_count_scope: 'returned_only', service_link_status: 'local_configured',
        availability_scope: 'service_confirmed', customer_offer_eligible: true, candidate_resource_ids: [local_resource.id]
      )
      expect(payload[:availability]).to include(status: 'local_only', resources: [include(resource_id: local_resource.id, status: 'local_only')])
      expect(payload[:slots].first).to include(availability_source: 'local', service_eligibility_status: 'local_configured')
      expect(payload[:service_match]).to eq(confirmed: true, service_id: service_record.id, resource_id: local_resource.id,
                                            resource_ids: [local_resource.id])
    end

    it 'does not label slots with a service status when no service was requested' do
      payload = perform(resource_ids: [local_resource.id], limit: 1)

      expect(payload).to include(service_link_status: 'not_requested', availability_scope: 'generic', customer_offer_eligible: false)
      expect(payload[:slots].first).not_to have_key(:service_eligibility_status)
    end

    it 'reports no offer when the range holds no free window' do
      payload = described_class.new(account: account, from: time_zone.local(2026, 4, 21, 9, 0, 0), to: time_zone.local(2026, 4, 21, 11, 0, 0),
                                    resource_ids: [local_resource.id], service_id: service_record.id).perform

      expect(payload).to include(slots: [], total_slots: 0, customer_offer_eligible: false, availability_scope: 'service_confirmed')
    end
  end

  describe 'a price link on a MedElement resource' do
    before { link(provider_resource) }

    it 'stays unverified even when the provider returns fresh times' do
      stub_provider(provider_resource.id => provider_result(status: 'fresh', slots: [provider_slot(provider_resource)]))

      payload = perform(resource_ids: [provider_resource.id], service_id: service_record.id, limit: 1)

      expect(payload[:availability][:status]).to eq('fresh')
      expect(payload[:total_slots]).to eq(1)
      expect(payload[:slots].first[:service_eligibility_status]).to eq('price_link_unverified')
      expect(payload).to include(availability_scope: 'service_unconfirmed', service_link_status: 'price_link_unverified',
                                 customer_offer_eligible: false, candidate_resource_ids: [provider_resource.id])
      expect(payload[:service_match]).to eq(confirmed: false, service_id: nil, resource_id: nil, resource_ids: [])
    end

    it 'does not offer anything when the provider is not configured for the account' do
      payload = perform(resource_ids: [provider_resource.id], service_id: service_record.id)

      expect(payload[:slots]).to be_empty
      expect(payload[:availability]).to include(
        status: 'degraded', resources: [include(provider: 'medelement', status: 'unavailable', reason: 'provider_configuration_missing')]
      )
      expect(payload).to include(customer_offer_eligible: false)
    end

    it 'does not claim provider confirmation after a provider time-out and never creates an appointment' do
      stub_provider(provider_resource.id => provider_result(status: 'unavailable', reason: 'provider_unavailable'))

      payload = perform(resource_ids: [provider_resource.id], service_id: service_record.id)

      expect(payload[:slots]).to be_empty
      expect(payload[:availability]).to include(status: 'degraded', resources: [include(status: 'unavailable', reason: 'provider_unavailable')])
      expect(payload).to include(customer_offer_eligible: false)
      expect(payload.to_s).not_to include('fresh')
      expect(Scheduling::Appointment.count).to eq(0)
    end
  end

  describe 'a diagnostic resource with provider cabinet data but without a specialist code' do
    let(:room) { create_resource('Cabinet', custom_attributes: { 'medelement_cabinets' => [{ 'cabinetCode' => 'room-1' }] }) }

    before { link(room) }

    it 'does not offer local windows as provider slots and never asks the provider' do
      expect(Integrations::Medelement::ResourceAvailabilityService).not_to receive(:new)

      payload = perform(resource_ids: [room.id], service_id: service_record.id, limit: 1)

      expect(payload[:slots]).to be_empty
      expect(payload[:availability]).to include(
        status: 'degraded', resources: [include(status: 'unavailable', reason: 'provider_resource_route_unverified')]
      )
      expect(payload).to include(service_link_status: 'price_link_unverified', customer_offer_eligible: false)
    end
  end

  describe 'two specialists sharing one room' do
    let(:cabinets) { [{ 'cabinetCode' => 'room-1' }] }
    let(:first_specialist) do
      create_resource('First', custom_attributes: { 'medelement_specialist_code' => 'a', 'medelement_cabinets' => cabinets })
    end
    let(:second_specialist) do
      create_resource('Second', custom_attributes: { 'medelement_specialist_code' => 'b', 'medelement_cabinets' => cabinets })
    end

    before do
      link(first_specialist)
      link(second_specialist)
    end

    it 'keeps the answer of each specialist apart and degrades the whole answer when one provider call fails' do
      stub_provider(
        first_specialist.id => provider_result(status: 'fresh', slots: [provider_slot(first_specialist)]),
        second_specialist.id => provider_result(status: 'unavailable', reason: 'provider_unavailable')
      )

      payload = perform(service_id: service_record.id)

      expect(payload[:slots].pluck(:resource_id)).to eq([first_specialist.id])
      expect(payload[:availability][:status]).to eq('degraded')
      expect(payload[:availability][:resources].pluck(:resource_id, :status)).to contain_exactly(
        [first_specialist.id, 'fresh'], [second_specialist.id, 'unavailable']
      )
      expect(payload[:candidate_resource_ids]).to contain_exactly(first_specialist.id, second_specialist.id)
      expect(payload).to include(customer_offer_eligible: false, service_link_status: 'price_link_unverified')
    end
  end

  describe 'mixed local and provider resources' do
    before do
      link(local_resource)
      link(provider_resource)
      stub_provider(provider_resource.id => provider_result(status: 'fresh', slots: [provider_slot(provider_resource)]))
    end

    it 'labels each slot by its own link while the answer as a whole is not offer-eligible' do
      payload = perform(service_id: service_record.id)

      statuses = payload[:slots].to_h { |slot| [slot[:resource_id], slot[:service_eligibility_status]] }
      expect(statuses).to include(local_resource.id => 'local_configured', provider_resource.id => 'price_link_unverified')
      expect(payload).to include(customer_offer_eligible: false, service_link_status: 'price_link_unverified')
    end
  end

  describe 'missing, inactive and foreign links' do
    it 'reports an incomplete import (a service with no links at all) as unconfirmed with no candidates' do
      payload = perform(service_id: service_record.id)

      expect(payload).to include(resources: [], slots: [], total_slots: 0, service_link_status: 'no_recorded_link',
                                 availability_scope: 'service_unconfirmed', customer_offer_eligible: false, candidate_resource_ids: [])
    end

    it 'rejects an explicitly requested resource whose link is inactive with the pinned message and a dedicated error class' do
      link(local_resource, active: false)

      expect { perform(resource_ids: [local_resource.id], service_id: service_record.id) }
        .to raise_error(described_class::MissingServiceLinkError, 'Service is not available for the requested specialists')
      expect(described_class::MissingServiceLinkError.ancestors).to include(ArgumentError)
    end

    it 'does not see resources or services of another account even when the names are identical' do
      foreign_resource = create(:scheduling_resource, account: other_account, name: 'Local')
      foreign_service = create(:scheduling_service, account: other_account, name: 'Consultation')

      expect { perform(resource_ids: [foreign_resource.id]) }.to raise_error(ActiveRecord::RecordNotFound)
      expect { perform(service_id: foreign_service.id) }.to raise_error(ActiveRecord::RecordNotFound)
    end

    it 'does not offer slots of an inactive resource that still has a price link' do
      link(local_resource)
      local_resource.update!(active: false)

      expect(perform(service_id: service_record.id)).to include(resources: [], slots: [], service_link_status: 'no_recorded_link')
    end
  end
end
