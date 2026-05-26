require 'rails_helper'

RSpec.describe 'Scheduling Resources API', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:headers) { admin.create_new_auth_token }
  let(:resource) { create(:scheduling_resource, account: account, compensation_type: 'fixed', compensation_value: 5_000) }

  before do
    account.enable_features!('scheduling')
  end

  def response_body
    response.parsed_body
  end

  it 'updates a resource to fixed plus percent compensation without auth header crashes' do
    patch "/api/v1/accounts/#{account.id}/scheduling/resources/#{resource.id}",
          params: {
            name: resource.name,
            specialty: resource.specialty,
            color: resource.color,
            timezone: resource.timezone,
            slot_duration_min: resource.slot_duration_min,
            compensation_type: 'fixed_plus_percent',
            compensation_value: 5_000,
            compensation_percent: 10,
            active: resource.active
          },
          headers: headers,
          as: :json

    expect(response).to have_http_status(:ok)
    expect(response_body.dig('payload', 'compensation_type')).to eq('fixed_plus_percent')
    expect(response_body.dig('payload', 'compensation_percent')).to eq(10)
  end

  it 'normalizes decimal zero resource compensation values' do
    patch "/api/v1/accounts/#{account.id}/scheduling/resources/#{resource.id}",
          params: {
            name: resource.name,
            timezone: resource.timezone,
            slot_duration_min: '45.0',
            compensation_type: 'fixed_plus_percent',
            compensation_value: '5000.00',
            compensation_percent: '10.0'
          },
          headers: headers,
          as: :json

    expect(response).to have_http_status(:ok)
    expect(resource.reload.slot_duration_min).to eq(45)
    expect(resource.compensation_value).to eq(5_000)
    expect(resource.compensation_percent).to eq(10)
  end

  it 'does not coerce non-integer resource fields through integer normalization' do
    patch "/api/v1/accounts/#{account.id}/scheduling/resources/#{resource.id}",
          params: {
            compensation_type: 'fixed_plus_percent',
            active: false,
            user_id: ''
          },
          headers: headers,
          as: :json

    expect(response).to have_http_status(:ok)
    expect(resource.reload.compensation_type).to eq('fixed_plus_percent')
    expect(resource.active).to be(false)
    expect(resource.user_id).to be_nil
  end

  it 'rejects fractional resource compensation values without truncating them' do
    patch "/api/v1/accounts/#{account.id}/scheduling/resources/#{resource.id}",
          params: {
            compensation_value: '5000.50'
          },
          headers: headers,
          as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response_body['error']).to eq('compensation_value must be an integer')
    expect(resource.reload.compensation_value).to eq(5_000)
  end

  it 'updates work rules without auth header crashes' do
    patch "/api/v1/accounts/#{account.id}/scheduling/resources/#{resource.id}/work_rules",
          params: {
            work_rules: [
              { weekday: 1, start_minute: 9 * 60, end_minute: 18 * 60, active: true }
            ]
          },
          headers: headers,
          as: :json

    expect(response).to have_http_status(:ok)
    expect(response_body.dig('payload', 0, 'weekday')).to eq(1)
  end

  it 'updates break rules without auth header crashes' do
    patch "/api/v1/accounts/#{account.id}/scheduling/resources/#{resource.id}/break_rules",
          params: {
            break_rules: [
              { weekday: 1, start_minute: 13 * 60, end_minute: 14 * 60, title: 'Lunch', active: true }
            ]
          },
          headers: headers,
          as: :json

    expect(response).to have_http_status(:ok)
    expect(response_body.dig('payload', 0, 'title')).to eq('Lunch')
  end

  it 'rejects deleting imported Medelement specialists' do
    imported_resource = create(
      :scheduling_resource,
      account: account,
      custom_attributes: { 'medelement_specialist_code' => '27492901726817790' }
    )

    delete "/api/v1/accounts/#{account.id}/scheduling/resources/#{imported_resource.id}",
           headers: headers,
           as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response_body['code']).to eq('RESOURCE_READ_ONLY')
  end

  it 'rejects deleting a specialist with a future active appointment and returns blocking details' do
    appointment = create(
      :scheduling_appointment,
      account: account,
      resource: resource,
      status: 'confirmed',
      starts_at: 1.day.from_now,
      ends_at: 1.day.from_now + 30.minutes
    )

    delete "/api/v1/accounts/#{account.id}/scheduling/resources/#{resource.id}",
           headers: headers,
           as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response_body['code']).to eq('RESOURCE_HAS_APPOINTMENTS')
    expect(response_body.dig('details', 'blocking_appointment_count')).to eq(1)
    expect(response_body.dig('details', 'blocking_appointments', 0)).to include(
      'id' => appointment.id,
      'status' => 'confirmed',
      'payment_status' => 'awaiting_payment'
    )
    expect(resource.reload.deleted_from_scheduling?).to be(false)
  end

  it 'rejects deleting a specialist with an in-progress active appointment' do
    create(
      :scheduling_appointment,
      account: account,
      resource: resource,
      status: 'scheduled',
      starts_at: 10.minutes.ago,
      ends_at: 20.minutes.from_now
    )

    delete "/api/v1/accounts/#{account.id}/scheduling/resources/#{resource.id}",
           headers: headers,
           as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response_body['code']).to eq('RESOURCE_HAS_APPOINTMENTS')
    expect(resource.reload.deleted_from_scheduling?).to be(false)
  end

  it 'archives a specialist with only a past stale scheduled appointment and preserves the appointment reference' do
    starts_at = 2.days.ago
    appointment = create(
      :scheduling_appointment,
      account: account,
      resource: resource,
      status: 'scheduled',
      starts_at: starts_at,
      ends_at: starts_at + 1.hour,
      payment_status: 'awaiting_payment'
    )

    delete "/api/v1/accounts/#{account.id}/scheduling/resources/#{resource.id}",
           headers: headers,
           as: :json

    expect(response).to have_http_status(:no_content)
    expect(resource.reload.active).to be(false)
    expect(resource.deleted_from_scheduling?).to be(true)
    expect(appointment.reload.resource_id).to eq(resource.id)
    expect(appointment.status).to eq('scheduled')
  end

  it 'archives a specialist when only terminal appointments remain' do
    create(
      :scheduling_appointment,
      account: account,
      resource: resource,
      status: 'completed',
      starts_at: 1.day.from_now,
      ends_at: 1.day.from_now + 30.minutes
    )
    create(
      :scheduling_appointment,
      account: account,
      resource: resource,
      status: 'no_show',
      starts_at: 2.days.from_now,
      ends_at: 2.days.from_now + 30.minutes
    )

    delete "/api/v1/accounts/#{account.id}/scheduling/resources/#{resource.id}",
           headers: headers,
           as: :json

    expect(response).to have_http_status(:no_content)
    expect(resource.reload.active).to be(false)
    expect(resource.deleted_from_scheduling?).to be(true)
  end

  it 'archives a specialist when only cancelled appointments remain' do
    create(
      :scheduling_appointment,
      account: account,
      resource: resource,
      status: 'cancelled',
      payment_status: 'cancelled'
    )

    delete "/api/v1/accounts/#{account.id}/scheduling/resources/#{resource.id}",
           headers: headers,
           as: :json

    expect(response).to have_http_status(:no_content)
    expect(resource.reload.active).to be(false)
    expect(resource.deleted_from_scheduling?).to be(true)
  end

  it 'archives an inactive specialist without appointments' do
    resource.update!(active: false)

    delete "/api/v1/accounts/#{account.id}/scheduling/resources/#{resource.id}",
           headers: headers,
           as: :json

    expect(response).to have_http_status(:no_content)
    expect(resource.reload.active).to be(false)
    expect(resource.deleted_from_scheduling?).to be(true)
  end

  it 'keeps deleting from scheduling idempotent for already archived specialists' do
    resource.archive_from_scheduling!

    delete "/api/v1/accounts/#{account.id}/scheduling/resources/#{resource.id}",
           headers: headers,
           as: :json

    expect(response).to have_http_status(:no_content)
    expect(resource.reload.active).to be(false)
    expect(resource.deleted_from_scheduling?).to be(true)
  end
end
