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

  it 'hides historical specialist compensation in both resource and calendar payloads' do
    resource
    get "/api/v1/accounts/#{account.id}/scheduling/resources",
        headers: headers,
        as: :json

    expect(response).to have_http_status(:ok)
    expect(response_body.fetch('payload').find { |item| item['id'] == resource.id }.keys).not_to include(
      'compensation_type', 'compensation_value', 'compensation_percent'
    )

    get "/api/v1/accounts/#{account.id}/scheduling/calendar",
        params: {
          view: 'week',
          from: Time.zone.parse('2026-03-09 00:00:00').iso8601,
          to: Time.zone.parse('2026-03-16 00:00:00').iso8601
        },
        headers: headers,
        as: :json

    expect(response).to have_http_status(:ok)
    expect(response_body.dig('payload', 'resources').find { |item| item['id'] == resource.id }.keys).not_to include(
      'compensation_type', 'compensation_value', 'compensation_percent'
    )
  end

  it 'updates a specialist schedule without auth header crashes' do
    patch "/api/v1/accounts/#{account.id}/scheduling/resources/#{resource.id}",
          params: {
            name: resource.name,
            specialty: resource.specialty,
            color: resource.color,
            timezone: resource.timezone,
            slot_duration_min: resource.slot_duration_min,
            active: resource.active
          },
          headers: headers,
          as: :json

    expect(response).to have_http_status(:ok)
    expect(response_body.dig('payload', 'schedule_update_supported')).to be(true)
    expect(response_body.dig('payload', 'availability_override_supported')).to be(true)
  end

  it 'normalizes a decimal zero slot duration' do
    patch "/api/v1/accounts/#{account.id}/scheduling/resources/#{resource.id}",
          params: {
            name: resource.name,
            timezone: resource.timezone,
            slot_duration_min: '45.0'
          },
          headers: headers,
          as: :json

    expect(response).to have_http_status(:ok)
    expect(resource.reload.slot_duration_min).to eq(45)
  end

  it 'does not coerce non-integer resource fields through integer normalization' do
    patch "/api/v1/accounts/#{account.id}/scheduling/resources/#{resource.id}",
          params: {
            active: false,
            user_id: ''
          },
          headers: headers,
          as: :json

    expect(response).to have_http_status(:ok)
    resource.reload
    expect(resource.active).to be(false)
    expect(resource.user_id).to be_nil
  end

  it 'rejects manually assigning provider-owned specialist metadata' do
    post "/api/v1/accounts/#{account.id}/scheduling/resources",
         params: {
           name: 'Spoofed specialist',
           custom_attributes: { medelement_specialist_code: 'spoofed-specialist' }
         },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response_body['code']).to eq('VALIDATION_ERROR')
    expect(account.scheduling_resources.where("custom_attributes ->> 'medelement_specialist_code' = ?", 'spoofed-specialist')).to be_empty
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

  it 'keeps accepting legacy multi-interval payloads during the compatibility rollout' do
    patch "/api/v1/accounts/#{account.id}/scheduling/resources/#{resource.id}/work_rules",
          params: {
            work_rules: [
              { weekday: 1, start_minute: 9 * 60, end_minute: 13 * 60, active: true },
              { weekday: 1, start_minute: 14 * 60, end_minute: 18 * 60, active: true }
            ]
          },
          headers: headers,
          as: :json

    expect(response).to have_http_status(:ok)
    expect(resource.work_rules.reload.pluck(:weekday, :start_minute, :end_minute)).to contain_exactly(
      [1, 9 * 60, 13 * 60],
      [1, 14 * 60, 18 * 60]
    )
  end

  it 'inherits company working hours and exposes the inheritance flag' do
    schedule = AccountWorkspaceWorkingHours::DEFAULT_SCHEDULE.deep_dup
    schedule[1].merge!('open_hour' => 10, 'close_hour' => 18)
    account.update!(
      workspace_working_hours_enabled: true,
      workspace_timezone: 'Asia/Almaty',
      workspace_working_hours: schedule
    )
    resource.work_rules.create!(weekday: 1, start_minute: 540, end_minute: 600, active: true)

    patch "/api/v1/accounts/#{account.id}/scheduling/resources/#{resource.id}",
          params: { inherit_working_hours_from_account: true },
          headers: headers,
          as: :json

    inherited_rule = resource.reload.work_rules.find_by!(weekday: 1)
    expect(response).to have_http_status(:ok)
    expect(response_body.dig('payload', 'inherit_working_hours_from_account')).to be(true)
    expect(resource.timezone).to eq('Asia/Almaty')
    expect(inherited_rule).to have_attributes(start_minute: 600, end_minute: 1080, active: true)
  end

  it 'inherits company working hours and breaks when the new client requests it' do
    account.update!(
      workspace_timezone: 'Asia/Almaty',
      workspace_working_hours: AccountWorkspaceWorkingHours::DEFAULT_SCHEDULE.deep_dup,
      workspace_breaks: [
        { days: [1, 2, 3, 4, 5], start_time: '13:00', end_time: '14:00', title: 'Lunch' }
      ]
    )

    post "/api/v1/accounts/#{account.id}/scheduling/resources",
         params: { name: 'New doctor', inherit_working_hours_from_account: true },
         headers: headers,
         as: :json

    created_resource = account.scheduling_resources.find(response_body.dig('payload', 'id'))
    expect(response).to have_http_status(:created)
    expect(created_resource.inherit_working_hours_from_account).to be(true)
    expect(created_resource.work_rules.find_by!(weekday: 1)).to have_attributes(start_minute: 540, end_minute: 1020, active: true)
    expect(created_resource.break_rules.find_by!(weekday: 1)).to have_attributes(start_minute: 780, end_minute: 840, title: 'Lunch')
  end

  it 'keeps legacy create requests on personal hours during a rolling rollout' do
    post "/api/v1/accounts/#{account.id}/scheduling/resources",
         params: { name: 'Legacy doctor' },
         headers: headers,
         as: :json

    created_resource = account.scheduling_resources.find(response_body.dig('payload', 'id'))
    expect(response).to have_http_status(:created)
    expect(created_resource.inherit_working_hours_from_account).to be(false)
    expect(created_resource.work_rules).to be_empty
  end

  it 'rejects custom work rules while company hours are inherited' do
    resource.update!(inherit_working_hours_from_account: true)

    patch "/api/v1/accounts/#{account.id}/scheduling/resources/#{resource.id}/work_rules",
          params: {
            work_rules: [
              { weekday: 1, start_minute: 9 * 60, end_minute: 18 * 60, active: true }
            ]
          },
          headers: headers,
          as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response_body['code']).to eq('WORK_RULES_INHERITED')
  end

  it 'rejects changing company-hours inheritance for an imported specialist' do
    imported_resource = create(
      :scheduling_resource,
      account: account,
      custom_attributes: { 'medelement_specialist_code' => '27492901726817790' }
    )

    patch "/api/v1/accounts/#{account.id}/scheduling/resources/#{imported_resource.id}",
          params: { inherit_working_hours_from_account: true },
          headers: headers,
          as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response_body['code']).to eq('RESOURCE_READ_ONLY')
    expect(imported_resource.reload.inherit_working_hours_from_account).to be(false)
  end

  it 'rejects legacy work-rule updates for an imported specialist' do
    imported_resource = create(
      :scheduling_resource,
      account: account,
      custom_attributes: { 'medelement_specialist_code' => '27492901726817790' }
    )

    patch "/api/v1/accounts/#{account.id}/scheduling/resources/#{imported_resource.id}/work_rules",
          params: { work_rules: [{ weekday: 1, start_minute: 540, end_minute: 1020, active: true }] },
          headers: headers,
          as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response_body['code']).to eq('RESOURCE_READ_ONLY')
  end

  it 'rejects legacy break-rule updates for an imported specialist' do
    imported_resource = create(
      :scheduling_resource,
      account: account,
      custom_attributes: { 'medelement_specialist_code' => '27492901726817790' }
    )

    patch "/api/v1/accounts/#{account.id}/scheduling/resources/#{imported_resource.id}/break_rules",
          params: { break_rules: [{ weekday: 1, start_minute: 720, end_minute: 780, active: true }] },
          headers: headers,
          as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response_body['code']).to eq('RESOURCE_READ_ONLY')
  end

  it 'updates inheritance, work rules, and breaks atomically' do
    revision = Scheduling::ResourceScheduleRevision.generate(resource)
    patch "/api/v1/accounts/#{account.id}/scheduling/resources/#{resource.id}/schedule",
          params: {
            expected_schedule_revision: revision,
            inherit_working_hours_from_account: false,
            work_rules: [{ weekday: 1, start_minute: 600, end_minute: 1080, active: true }],
            break_rules: [{ weekday: 1, start_minute: 780, end_minute: 840, title: 'Lunch', active: true }]
          },
          headers: headers,
          as: :json

    expect(response).to have_http_status(:ok), response.body
    expect(resource.reload.work_rules.find_by!(weekday: 1)).to have_attributes(start_minute: 600, end_minute: 1080)
    expect(resource.break_rules.find_by!(weekday: 1)).to have_attributes(start_minute: 780, end_minute: 840)
  end

  it 'requires the inheritance flag for an atomic schedule update' do
    original_rule = resource.work_rules.create!(weekday: 2, start_minute: 540, end_minute: 1020, active: true)

    patch "/api/v1/accounts/#{account.id}/scheduling/resources/#{resource.id}/schedule",
          params: { work_rules: [], break_rules: [] },
          headers: headers,
          as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(resource.reload.inherit_working_hours_from_account).to be(false)
    expect(resource.work_rules).to contain_exactly(original_rule)
  end

  it 'rolls back the full schedule when one rule is invalid' do
    original_rule = resource.work_rules.create!(weekday: 2, start_minute: 540, end_minute: 1020, active: true)
    revision = Scheduling::ResourceScheduleRevision.generate(resource.reload)

    patch "/api/v1/accounts/#{account.id}/scheduling/resources/#{resource.id}/schedule",
          params: {
            expected_schedule_revision: revision,
            inherit_working_hours_from_account: false,
            work_rules: [{ weekday: 1, start_minute: 600, end_minute: 1080, active: true }],
            break_rules: [{ weekday: 1, start_minute: 900, end_minute: 800, active: true }]
          },
          headers: headers,
          as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(resource.work_rules.reload).to contain_exactly(original_rule)
  end

  it 'returns one consistent schedule snapshot with an opaque revision' do
    resource.work_rules.create!(weekday: 1, start_minute: 540, end_minute: 1020, active: true)
    resource.break_rules.create!(weekday: 1, start_minute: 780, end_minute: 840, title: 'Lunch', active: true)

    get "/api/v1/accounts/#{account.id}/scheduling/resources/#{resource.id}/schedule", headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(response_body.dig('payload', 'schedule_revision')).to match(/\A[0-9a-f]{64}\z/)
    expect(response_body.dig('payload', 'work_rules', 0, 'weekday')).to eq(1)
    expect(response_body.dig('payload', 'break_rules', 0, 'title')).to eq('Lunch')
  end

  it 'rejects a stale schedule revision without changing the newer schedule' do
    stale_revision = Scheduling::ResourceScheduleRevision.generate(resource)
    newer_rule = resource.work_rules.create!(weekday: 2, start_minute: 540, end_minute: 1020, active: true)

    patch "/api/v1/accounts/#{account.id}/scheduling/resources/#{resource.id}/schedule",
          params: {
            expected_schedule_revision: stale_revision,
            inherit_working_hours_from_account: false,
            work_rules: [{ weekday: 1, start_minute: 600, end_minute: 1080, active: true }],
            break_rules: []
          },
          headers: headers,
          as: :json

    expect(response).to have_http_status(:conflict), response.body
    expect(response_body['code']).to eq('SCHEDULE_VERSION_CONFLICT')
    expect(response_body.dig('details', 'current_schedule_revision')).to match(/\A[0-9a-f]{64}\z/)
    expect(resource.work_rules.reload).to contain_exactly(newer_rule)
  end

  it 'rejects malformed schedule rule containers and elements without mutation' do
    original_rule = resource.work_rules.create!(weekday: 2, start_minute: 540, end_minute: 1020, active: true)
    revision = Scheduling::ResourceScheduleRevision.generate(resource.reload)

    [{}, ['bad']].each do |invalid_rules|
      patch "/api/v1/accounts/#{account.id}/scheduling/resources/#{resource.id}/schedule",
            params: {
              expected_schedule_revision: revision,
              inherit_working_hours_from_account: false,
              work_rules: invalid_rules,
              break_rules: []
            },
            headers: headers,
            as: :json

      expect(response).to have_http_status(:unprocessable_content), response.body
      expect(response_body['code']).to eq('INVALID_SCHEDULE_PAYLOAD')
      expect(resource.work_rules.reload).to contain_exactly(original_rule)
    end
  end

  it 'rejects malformed legacy work-rule payloads without mutation' do
    original_rule = resource.work_rules.create!(weekday: 2, start_minute: 540, end_minute: 1020, active: true)

    [{}, ['bad']].each do |invalid_rules|
      patch "/api/v1/accounts/#{account.id}/scheduling/resources/#{resource.id}/work_rules",
            params: { work_rules: invalid_rules },
            headers: headers,
            as: :json

      expect(response).to have_http_status(:unprocessable_content), response.body
      expect(response_body['code']).to eq('INVALID_SCHEDULE_PAYLOAD')
      expect(resource.work_rules.reload).to contain_exactly(original_rule)
    end
  end

  it 'rejects malformed legacy break-rule payloads without mutation' do
    original_break = resource.break_rules.create!(
      weekday: 2,
      start_minute: 780,
      end_minute: 840,
      title: 'Lunch',
      active: true
    )

    [{}, ['bad']].each do |invalid_rules|
      patch "/api/v1/accounts/#{account.id}/scheduling/resources/#{resource.id}/break_rules",
            params: { break_rules: invalid_rules },
            headers: headers,
            as: :json

      expect(response).to have_http_status(:unprocessable_content), response.body
      expect(response_body['code']).to eq('INVALID_SCHEDULE_PAYLOAD')
      expect(resource.break_rules.reload).to contain_exactly(original_break)
    end
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

  it 'rejects custom break rules while company hours are inherited' do
    resource.update!(inherit_working_hours_from_account: true)

    patch "/api/v1/accounts/#{account.id}/scheduling/resources/#{resource.id}/break_rules",
          params: {
            break_rules: [
              { weekday: 1, start_minute: 13 * 60, end_minute: 14 * 60, title: 'Custom break', active: true }
            ]
          },
          headers: headers,
          as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response_body['code']).to eq('BREAK_RULES_INHERITED')
  end

  it 'rejects modifying imported Medelement specialist identity' do
    imported_resource = create(
      :scheduling_resource,
      account: account,
      custom_attributes: { 'medelement_specialist_code' => '27492901726817790' }
    )

    patch "/api/v1/accounts/#{account.id}/scheduling/resources/#{imported_resource.id}",
          params: { name: 'Changed locally' },
          headers: headers,
          as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response_body['code']).to eq('RESOURCE_READ_ONLY')
    expect(imported_resource.reload.name).not_to eq('Changed locally')
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
      'status' => 'confirmed'
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
