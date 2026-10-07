require 'rails_helper'

# The local-rules availability tool never asks MedElement and must say so, also for a provider-linked resource.
RSpec.describe Captain::Tools::Copilot::GetSchedulingResourceAvailabilityService do
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

  def windows(resource, **arguments)
    JSON.parse(tool.execute(resource_id: resource.id, from: from_time.iso8601, to: to_time.iso8601, **arguments))
  end

  it 'labels local windows of a locally configured resource as an eligible local offer' do
    resource = create_resource('Local')
    link(resource)

    payload = windows(resource, service_id: service_record.id, limit: 2)

    expect(payload).to include('availability_source' => 'local_rules', 'provider_checked' => false, 'provider_required' => false,
                               'service_link_status' => 'local_configured', 'customer_offer_eligible' => true)
    expect(payload.dig('service', 'prices')).to eq([])
  end

  it 'never calls the provider and never claims a provider answer, also for a MedElement resource' do
    resource = create_resource('Provider', custom_attributes: { 'medelement_specialist_code' => 'code-1' })
    link(resource)
    expect(Integrations::Medelement::ResourceAvailabilityService).not_to receive(:new)

    payload = windows(resource, service_id: service_record.id)

    expect(payload).to include('availability_source' => 'local_rules', 'provider_checked' => false, 'provider_required' => true,
                               'customer_offer_eligible' => false)
    expect(payload.to_s).not_to include('fresh')
  end

  it 'labels an existing confirmed snapshot while retaining local-only availability' do
    resource = create_resource('Provider', custom_attributes: { 'medelement_specialist_code' => 'doctor-1' })
    hook = create(:integrations_hook, :medelement, account: account)
    Integrations::Medelement::ScheduleDay.create!(
      account: account, hook: hook, resource: resource, specialist_code: 'doctor-1',
      date: Date.new(2026, 4, 20), status: 'confirmed', source_checked_at: from_time,
      windows: [{ start_minute: 600, end_minute: 720 }]
    )

    payload = windows(resource)

    expect(payload['provider_schedule_note']).to include('по данным MedElement на', '10:00–12:00')
    expect(payload).to include('availability_source' => 'local_rules', 'provider_checked' => false)
  end

  it 'marks no service as not requested and an inactive link as an explicit error' do
    resource = create_resource('Local')
    link(resource, active: false)

    expect(windows(resource)).to include('service_link_status' => 'not_requested', 'customer_offer_eligible' => false)
    expect(tool.execute(resource_id: resource.id, from: from_time.iso8601, to: to_time.iso8601, service_id: service_record.id))
      .to start_with('ERROR:').and(include('No recorded service-price link'))
  end

  it 'does not return a resource of another account' do
    foreign = create(:scheduling_resource, account: create(:account), name: 'Local')

    expect(tool.execute(resource_id: foreign.id, from: from_time.iso8601, to: to_time.iso8601)).to start_with('ERROR:')
  end

  it 'rejects a recorded link whose price row belongs to another account' do
    resource = create_resource('Local')
    link(resource).update_columns(account_id: create(:account).id) # rubocop:disable Rails/SkipsModelValidations

    result = tool.execute(resource_id: resource.id, from: from_time.iso8601, to: to_time.iso8601,
                          service_id: service_record.id)
    expect(result).to start_with('ERROR:')
  end
end
