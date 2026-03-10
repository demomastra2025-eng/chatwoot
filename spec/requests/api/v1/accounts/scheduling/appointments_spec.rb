require 'rails_helper'

RSpec.describe 'Scheduling Appointments API', type: :request do
  let(:account) { create(:account) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:resource) { create(:scheduling_resource, account: account, timezone: 'Asia/Almaty') }
  let(:service) { create(:scheduling_service, account: account, base_price: 20_000) }
  let(:contact) { create(:contact, account: account, name: 'Test Patient', phone_number: '+77015554433') }
  let(:headers) { agent.create_new_auth_token }
  let(:booking_day) { ActiveSupport::TimeZone['Asia/Almaty'].local(2026, 3, 9, 10, 0, 0) }
  let(:path) { "/api/v1/accounts/#{account.id}/scheduling/appointments" }

  before do
    account.enable_features!('scheduling', 'scheduling_finance')
  end

  let!(:work_rule) do
    create(:scheduling_work_rule, resource: resource, account: account, weekday: 1, start_minute: 9 * 60, end_minute: 18 * 60)
  end

  let(:base_params) do
    {
      resource_id: resource.id,
      contact_id: contact.id,
      service_id: service.id,
      starts_at: booking_day.iso8601,
      ends_at: (booking_day + 30.minutes).iso8601,
      client_name: 'Test Patient',
      client_phone: '+77015554433',
      service_amount: 20_000
    }
  end

  def response_body
    response.parsed_body
  end

  it 'creates an appointment inside a valid slot' do
    post path, params: base_params, headers:, as: :json

    expect(response).to have_http_status(:created)
    expect(response_body.dig('payload', 'resource_id')).to eq(resource.id)
    expect(response_body.dig('payload', 'service_id')).to eq(service.id)
  end

  it 'rejects appointment outside working hours' do
    post path, params: base_params.merge(starts_at: booking_day.change(hour: 8).iso8601, ends_at: booking_day.change(hour: 8, min: 30).iso8601), headers:, as: :json

    expect(response).to have_http_status(:conflict)
    expect(response_body['code']).to eq('OUTSIDE_WORKING_HOURS')
  end

  it 'rejects holiday conflicts' do
    create(:scheduling_holiday, account: account, date: booking_day.to_date)

    post path, params: base_params, headers:, as: :json

    expect(response).to have_http_status(:conflict)
    expect(response_body['code']).to eq('BLOCKED_BY_HOLIDAY')
  end

  it 'rejects break conflicts' do
    create(:scheduling_break_rule, resource: resource, account: account, weekday: 1, start_minute: 10 * 60, end_minute: 11 * 60)

    post path, params: base_params, headers:, as: :json

    expect(response).to have_http_status(:conflict)
    expect(response_body['code']).to eq('BLOCKED_BY_BREAK')
  end

  it 'rejects time off conflicts' do
    create(:scheduling_time_off, resource: resource, account: account, starts_at: booking_day, ends_at: booking_day + 2.hours)

    post path, params: base_params, headers:, as: :json

    expect(response).to have_http_status(:conflict)
    expect(response_body['code']).to eq('BLOCKED_BY_VACATION')
  end

  it 'rejects appointment overlap conflicts' do
    create(
      :scheduling_appointment,
      resource: resource,
      account: account,
      contact: contact,
      service: service,
      starts_at: booking_day,
      ends_at: booking_day + 1.hour
    )

    post path, params: base_params, headers:, as: :json

    expect(response).to have_http_status(:conflict)
    expect(response_body['code']).to eq('SLOT_CONFLICT')
  end

  it 'rejects inactive service-resource combinations' do
    service.update!(active: false)

    post path, params: base_params, headers:, as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response_body['code']).to eq('SERVICE_NOT_AVAILABLE_FOR_RESOURCE')
  end

  it 'replays idempotent create requests with status 200' do
    params = base_params.merge(idempotency_key: 'idem-1')

    post path, params:, headers:, as: :json
    created_id = response_body.dig('payload', 'id')

    post path, params:, headers:, as: :json

    expect(response).to have_http_status(:ok)
    expect(response_body.dig('payload', 'id')).to eq(created_id)
    expect(account.scheduling_appointments.where(idempotency_key: 'idem-1').count).to eq(1)
  end

  it 'rejects duplicate external_ref values' do
    create(
      :scheduling_appointment,
      resource: resource,
      account: account,
      contact: contact,
      service: service,
      external_ref: 'ext-1'
    )

    post path, params: base_params.merge(external_ref: 'ext-1'), headers:, as: :json

    expect(response).to have_http_status(:conflict)
    expect(response_body['code']).to eq('DUPLICATE_EXTERNAL_REF')
  end

  it 'rejects invalid IIN values in appointment payloads' do
    post path, params: base_params.merge(client_identifier: '123456789012'), headers:, as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response_body['code']).to eq('INVALID_IIN')
  end

  it 'returns a stable calendar payload shape' do
    appointment = create(
      :scheduling_appointment,
      resource: resource,
      account: account,
      contact: contact,
      service: service,
      starts_at: booking_day,
      ends_at: booking_day + 30.minutes,
      payment_status: 'paid',
      settlement_amount: 20_000,
      settlement_payment_method: 'cash'
    )
    create(:scheduling_holiday, account: account, date: booking_day.to_date + 1.day)
    create(:scheduling_workday_override, resource: resource, account: account, date: booking_day.to_date + 2.days)
    create(:scheduling_time_off, resource: resource, account: account, starts_at: booking_day + 3.days, ends_at: booking_day + 3.days + 2.hours)
    create(:scheduling_payment, appointment: appointment, account: account, amount: 20_000, payment_method: 'cash', payment_kind: 'payment')
    create(:scheduling_expense, appointment: appointment, account: account, resource: resource, amount: 8_000)

    get "/api/v1/accounts/#{account.id}/scheduling/calendar",
        params: {
          view: 'week',
          from: booking_day.beginning_of_day.iso8601,
          to: (booking_day + 7.days).end_of_day.iso8601,
          include_slots: true
        },
        headers:,
        as: :json

    expect(response).to have_http_status(:ok)
    expect(response_body['payload'].keys).to include(
      'resources', 'work_rules', 'break_rules', 'holidays', 'workday_overrides',
      'time_offs', 'appointments', 'payments', 'expenses', 'slots'
    )
  end
end
