require 'rails_helper'

# Integrated resources require a live provider answer before windows are returned.
RSpec.describe Captain::Tools::Copilot::GetSchedulingResourceAvailabilityService do
  include ActiveSupport::Testing::TimeHelpers

  around { |example| travel_to(Time.utc(2026, 4, 19, 12)) { example.run } }

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
                               'service_link_status' => 'local_configured')
    expect(payload.dig('service', 'prices')).to eq([])
  end

  it 'returns no local windows when provider access is unavailable' do
    resource = create_resource('Provider', custom_attributes: { 'medelement_specialist_code' => 'code-1' })
    link(resource)
    expect(Integrations::Medelement::ResourceAvailabilityService).to receive(:new).and_call_original

    payload = windows(resource, service_id: service_record.id)

    expect(payload).to include('availability_source' => 'medelement', 'provider_checked' => false, 'provider_required' => true)
    expect(payload['slots']).to be_empty
    expect(payload).not_to have_key('customer_offer_eligible')
    expect(payload.to_s).not_to include('fresh')
  end

  it 'clips integrated availability beyond the provider horizon' do
    resource = create_resource('Provider', custom_attributes: { 'medelement_specialist_code' => 'doctor-1' })
    zone = ActiveSupport::TimeZone['Asia/Almaty']
    date = zone.today + 90
    from = zone.local(date.year, date.month, date.day, 9)
    expect(Integrations::Medelement::ResourceAvailabilityService).not_to receive(:new)

    payload = JSON.parse(tool.execute(resource_id: resource.id, from: from.iso8601, to: (from + 1.hour).iso8601))

    expect(payload['slots']).to be_empty
    expect(payload.dig('availability', 'resources', 0, 'status')).to eq('outside_horizon')
    expect(payload['availability_note']).to include((date - 1).strftime('%d.%m.%Y'))
  end

  it 'keeps a provider schedule note without claiming a live result' do
    resource = create_resource('Provider', custom_attributes: { 'medelement_specialist_code' => 'doctor-1' })
    hook = create(:integrations_hook, :medelement, account: account)
    Integrations::Medelement::ScheduleDay.create!(
      account: account, hook: hook, resource: resource, specialist_code: 'doctor-1',
      date: Date.new(2026, 4, 20), status: 'confirmed', source_checked_at: from_time,
      windows: [{ start_minute: 600, end_minute: 720 }]
    )

    payload = windows(resource)

    expect(payload['provider_schedule_note']).to include('по данным MedElement на', '10:00–12:00')
    expect(payload).to include('availability_source' => 'medelement', 'provider_checked' => false)
  end

  it 'marks no service as not requested and an inactive link as an explicit error' do
    resource = create_resource('Local')
    link(resource, active: false)

    expect(windows(resource)).to include('service_link_status' => 'not_requested')
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
