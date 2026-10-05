require 'rails_helper'

# What the LLM is told about the source and the eligibility of the times it receives. The pinned MedElement contract
# spec (search_available_slots_service_spec.rb) is intentionally left untouched.
RSpec.describe Captain::Tools::Copilot::SearchAvailableSlotsService do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:tool) { described_class.new(assistant, user: user) }
  let(:service_record) { create(:scheduling_service, account: account, name: 'Consultation', duration_min: 30) }
  let(:from_time) { Time.zone.parse('2026-04-20 09:00:00 +0500') }
  let(:to_time) { Time.zone.parse('2026-04-20 11:00:00 +0500') }

  before { account.enable_features!('scheduling') }

  def create_resource(name, **attributes)
    create(:scheduling_resource, account: account, name: name, timezone: 'Asia/Almaty', **attributes).tap do |record|
      create(:scheduling_work_rule, account: account, resource: record, weekday: 1, start_minute: 9 * 60, end_minute: 11 * 60)
    end
  end

  def link(resource, active: true)
    create(:scheduling_service_price, account: account, service: service_record, resource: resource, active: active)
  end

  def search(**arguments)
    JSON.parse(tool.execute(from: from_time.iso8601, to: to_time.iso8601, **arguments))
  end

  it 'explains a missing link with the pinned message plus a plain statement that eligibility is unverified' do
    resource = create_resource('Local')
    link(resource, active: false)

    result = tool.execute(from: from_time.iso8601, to: to_time.iso8601, resource_ids: [resource.id], service_id: service_record.id)

    expect(result).to start_with('ERROR:')
    expect(result).to include('Service is not available for the requested specialists')
    expect(result).to include('no recorded service-price link', 'eligibility is unverified')
  end

  it 'reports a confirmed local link with the local source' do
    resource = create_resource('Local')
    link(resource)

    payload = search(resource_ids: [resource.id], service_id: service_record.id, limit: 2)

    expect(payload).to include('total_slots' => 2, 'slot_count_scope' => 'returned_only', 'service_link_status' => 'local_configured',
                               'customer_offer_eligible' => true, 'candidate_resource_ids' => [resource.id])
    expect(payload['availability']).to include('status' => 'local_only')
  end

  it 'publishes the service match as missing for a MedElement-linked resource' do
    resource = create_resource('Provider', custom_attributes: { 'medelement_specialist_code' => 'code-1' })
    link(resource)
    allow(Llm::EventBus).to receive(:publish)

    payload = search(resource_ids: [resource.id], service_id: service_record.id)

    expect(payload).to include('customer_offer_eligible' => false, 'service_link_status' => 'price_link_unverified')
    expect(Llm::EventBus).to have_received(:publish).with('captain.service_match_missing', hash_including(resource_ids: []))
  end

  it 'tells the model that nothing is confirmed after a provider failure and creates no appointment' do
    resource = create_resource('Provider', custom_attributes: { 'medelement_specialist_code' => 'code-1' })
    link(resource)
    failed = Integrations::Medelement::ResourceAvailabilityService::Result.new(
      status: 'unavailable', checked_at: Time.current, slots: [], reason: 'provider_unavailable'
    )
    allow(Integrations::Medelement::ResourceAvailabilityService).to receive(:new)
      .and_return(instance_double(Integrations::Medelement::ResourceAvailabilityService, perform: failed))

    payload = search(resource_ids: [resource.id], service_id: service_record.id)

    expect(payload).to include('slots' => [], 'total_slots' => 0, 'customer_offer_eligible' => false)
    expect(payload['availability']).to include('status' => 'degraded')
    expect(Scheduling::Appointment.count).to eq(0)
  end
end
