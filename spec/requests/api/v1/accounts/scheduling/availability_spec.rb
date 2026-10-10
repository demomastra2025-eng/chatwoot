require 'rails_helper'

RSpec.describe 'Scheduling Availability API', type: :request do
  include ActiveSupport::Testing::TimeHelpers

  around { |example| travel_to(Time.utc(2026, 4, 19, 20)) { example.run } }

  let(:account) { create(:account) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:headers) { agent.create_new_auth_token }
  let(:hook) { create(:integrations_hook, :medelement, account: account) }
  let(:resource) do
    create(:scheduling_resource, account: account, timezone: 'Asia/Almaty',
                                 custom_attributes: {
                                   'medelement_specialist_code' => 'specialist-1',
                                   'medelement_cabinets' => [{ 'companyCabinetCode' => 'cabinet-1' }]
                                 })
  end
  let(:path) { "/api/v1/accounts/#{account.id}/scheduling/availability" }

  before do
    account.enable_features!('scheduling')
    hook
  end

  def request_day(date = '2026-04-20', **extra)
    get path, params: { resource_id: resource.id, date: date, **extra }, headers: headers, as: :json
    response.parsed_body.fetch('payload')
  end

  def create_day(status: 'confirmed', checked_at: Time.current, on: Date.new(2026, 4, 20), windows: [{ start_minute: 10 * 60, end_minute: 11 * 60 }])
    Integrations::Medelement::ScheduleDay.create!(
      account: account, hook: hook, resource: resource, specialist_code: 'specialist-1',
      date: on, status: status, source_checked_at: checked_at,
      windows: status == 'confirmed' ? windows : []
    )
  end

  it 'returns verified available windows and metadata to an account agent without provider HTTP' do
    create_day
    expect(Integrations::Medelement::Client).not_to receive(:new)
    payload = request_day

    expect(response).to have_http_status(:ok)
    expect(payload).to include('state' => 'ok', 'source' => 'provider_schedule', 'last_bookable_date' => nil)
    expect(payload['checked_at']).to be_present
    expect(payload['windows'].first).to include('cabinet_code' => 'cabinet-1')
  end

  it 'distinguishes closed, unconfirmed and unavailable provider days' do
    create_day(status: 'empty_confirmed')
    expect(request_day['state']).to eq('closed_day')
    expect(request_day['windows']).to be_empty

    resource.update!(custom_attributes: resource.custom_attributes.merge('medelement_specialist_code' => 'specialist-2'))
    expect(request_day['state']).to eq('schedule_not_confirmed')
    hook.update!(status: Integrations::Hook.statuses['disabled'])
    expect(request_day['state']).to eq('provider_unavailable')
  end

  it 'reads a later confirmed date on demand without a booking cutoff' do
    client = instance_double(Integrations::Medelement::Client, get_receptions: [])
    allow(client).to receive(:timetable).and_return(
      '19.07.2026' => { 'timetable' => [{ 'start' => '19.07.2026 10:00', 'end' => '19.07.2026 11:00', 'working' => true }] }
    )
    allow(Integrations::Medelement::Client).to receive(:new).and_return(client)
    payload = request_day('2026-07-19', confirmed_only: 'false')
    expect(payload).to include('state' => 'ok', 'last_bookable_date' => nil)
    expect(payload['windows']).to be_present
    expect(payload).not_to have_key('code')
  end

  it 'returns partial verified slots for the same service, cabinet and full duration without live range reads' do
    service = create(:scheduling_service, account: account, duration_min: 30)
    create(:scheduling_service_price, account: account, resource: resource, service: service)
    resource.update!(custom_attributes: resource.custom_attributes.merge(
      'medelement_cabinets' => [{ 'companyCabinetCode' => 'cabinet-1' }, { 'companyCabinetCode' => 'cabinet-2' }]
    ))
    create_day(status: 'empty_confirmed', on: Date.new(2026, 4, 21))
    create_day(status: 'unverified', on: Date.new(2026, 4, 22))
    create_day(on: Date.new(2026, 4, 23), checked_at: 2.days.ago)
    create_day(on: Date.new(2026, 4, 24), windows: [{ start_minute: 600, end_minute: 690, cabinet_code: 'cabinet-2' }])
    create_day(on: Date.new(2026, 4, 25), windows: [{ start_minute: 600, end_minute: 660, cabinet_code: 'cabinet-1' }])
    create_day(on: Date.new(2026, 4, 26), windows: [{ start_minute: 600, end_minute: 690, cabinet_code: 'cabinet-1' }])
    expect(Integrations::Medelement::Client).not_to receive(:new)
    expect(Integrations::Medelement::ResourceAvailabilityService).not_to receive(:new)

    get path, params: { resource_id: resource.id, service_id: service.id, duration_min: 75, cabinet_code: 'cabinet-1',
                        date_from: '2026-04-21', date_to: '2026-05-21', confirmed_only: true }, headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    payload = response.parsed_body.fetch('payload')
    expect(payload).to include('state' => 'schedule_not_confirmed', 'source' => 'provider_schedule')
    expected_windows = [['10:00', '11:15'], ['10:05', '11:20'], ['10:10', '11:25'], ['10:15', '11:30']].map do |starts_at, ends_at|
      { 'cabinet_code' => 'cabinet-1', 'starts_at' => "2026-04-26T#{starts_at}:00+05:00", 'ends_at' => "2026-04-26T#{ends_at}:00+05:00" }
    end
    expect(payload.fetch('windows')).to eq(expected_windows)
  end

  it 'keeps a missing future 31-day range unconfirmed in confirmed-only mode' do
    expect(Integrations::Medelement::Client).not_to receive(:new)
    expect(Integrations::Medelement::ResourceAvailabilityService).not_to receive(:new)
    get path, params: { resource_id: resource.id, date_from: '2026-07-20', date_to: '2026-08-19', confirmed_only: true },
              headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch('payload')).to include('state' => 'schedule_not_confirmed', 'windows' => [])
  end

  it 'distinguishes a fully confirmed empty range from unknown days and an unavailable provider' do
    (Date.new(2026, 4, 21)..Date.new(2026, 5, 21)).each { |day| create_day(status: 'empty_confirmed', on: day) }
    expect(Integrations::Medelement::Client).not_to receive(:new)
    get path, params: { resource_id: resource.id, date_from: '2026-04-21', date_to: '2026-05-21', confirmed_only: true },
              headers: headers, as: :json
    expect(response.parsed_body.fetch('payload')).to include('state' => 'closed_day', 'windows' => [])

    hook.update!(status: Integrations::Hook.statuses['disabled'])
    expect(request_day('2026-04-21', confirmed_only: true)).to include('state' => 'provider_unavailable', 'windows' => [])
  end

  it 'uses an explicitly authored duration even when a service has a different default' do
    service = create(:scheduling_service, account: account, duration_min: 30)
    create(:scheduling_service_price, account: account, resource: resource, service: service)
    create_day

    payload = request_day(service_id: service.id, duration_min: 45)
    first = payload.fetch('windows').first
    expect(Time.iso8601(first.fetch('ends_at')) - Time.iso8601(first.fetch('starts_at'))).to eq(45.minutes)
    expect(request_day(service_id: service.id, duration_min: 75)['windows']).to be_empty
  end

  it 'rejects ranges longer than 31 days' do
    get path, params: { resource_id: resource.id, date_from: '2026-04-20', date_to: '2026-05-21' },
              headers: headers, as: :json
    expect(response).to have_http_status(:unprocessable_content)
  end

  it 'uses local rules for a non-integrated resource' do
    local = create(:scheduling_resource, account: account, timezone: 'Asia/Almaty')
    create(:scheduling_work_rule, account: account, resource: local, weekday: 1,
                                  start_minute: 10 * 60, end_minute: 11 * 60)
    payload = request_day('2026-04-20', resource_id: local.id)
    expect(payload['source']).to eq('local_rules')
    expect(payload['windows']).to be_present
  end

  it 'requires account membership and the scheduling feature' do
    outsider = create(:user)
    get path, params: { resource_id: resource.id, date: '2026-04-20' },
              headers: outsider.create_new_auth_token, as: :json
    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body).to eq('error' => 'You are not authorized to access this account')

    account.disable_features!('scheduling')
    get path, params: { resource_id: resource.id, date: '2026-04-20' }, headers: headers, as: :json
    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body).to include('code' => 'FEATURE_DISABLED')
    expect(response.parsed_body).not_to have_key('payload')
  end
end
