require 'rails_helper'

RSpec.describe 'Specialist schedule updates', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:headers) { admin.create_new_auth_token }
  let(:resource) { create(:scheduling_resource, account: account, inherit_working_hours_from_account: false) }

  before { account.enable_features!('scheduling') }

  def update_schedule(payload)
    patch "/api/v1/accounts/#{account.id}/scheduling/resources/#{resource.id}", params: payload, headers: headers, as: :json
  end

  def rule_snapshot
    [resource.reload.inherit_working_hours_from_account, resource.work_rules.order(:id).map(&:attributes),
     resource.break_rules.order(:id).map(&:attributes)]
  end

  it 'rejects duplicate working weekdays before replacing the saved schedule' do
    original = create(:scheduling_work_rule, account: account, resource: resource, weekday: 2)
    patch "/api/v1/accounts/#{account.id}/scheduling/resources/#{resource.id}/work_rules",
          params: { work_rules: [{ weekday: 1, start_minute: 540, end_minute: 720, active: true },
                                 { weekday: '1', start_minute: 780, end_minute: 1020, active: true }] },
          headers: headers, as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body['code']).to eq('DUPLICATE_WORK_WEEKDAY')
    expect(resource.work_rules.reload.pluck(:id)).to eq([original.id])
  end

  it 'saves inheritance, personal hours and multiple distinct breaks in one update' do
    resource.update!(inherit_working_hours_from_account: true)
    resource.apply_workspace_working_hours!
    update_schedule(inherit_working_hours_from_account: false,
                    work_rules: [{ weekday: 1, start_minute: 600, end_minute: 1020, active: true }],
                    break_rules: [{ weekday: 1, start_minute: 720, end_minute: 750, title: 'Lunch', active: true },
                                  { weekday: 1, start_minute: 900, end_minute: 915, title: 'Rest', active: true }])

    expect(response).to have_http_status(:ok)
    expect(resource.reload.inherit_working_hours_from_account?).to be(false)
    expect(resource.work_rules.pluck(:weekday, :start_minute, :end_minute, :active)).to eq([[1, 600, 1020, true]])
    expect(resource.break_rules.ordered.pluck(:start_minute, :end_minute, :active)).to eq([[720, 750, true], [900, 915, true]])
  end

  it 'rolls back inheritance and both rule sets when a break is invalid' do
    resource.update!(inherit_working_hours_from_account: true)
    resource.apply_workspace_working_hours!
    previous = rule_snapshot
    update_schedule(inherit_working_hours_from_account: false,
                    work_rules: [{ weekday: 1, start_minute: 600, end_minute: 1020, active: true }],
                    break_rules: [{ weekday: 1, start_minute: 900, end_minute: 800, active: true }])

    expect(response).to have_http_status(:unprocessable_content)
    expect(rule_snapshot).to eq(previous)
  end

  it 'rolls back the resource when a working weekday is invalid' do
    previous_name = resource.name
    original = create(:scheduling_work_rule, account: account, resource: resource, weekday: 2)
    update_schedule(name: 'Unsaved name', work_rules: [{ weekday: 9, start_minute: 600, end_minute: 900, active: true }])

    expect(response).to have_http_status(:unprocessable_content)
    expect(resource.reload.name).to eq(previous_name)
    expect(resource.work_rules.reload.pluck(:id)).to eq([original.id])
  end

  it 'keeps omitted rule sets, overrides and time off when changing profile fields' do
    work_rule = create(:scheduling_work_rule, account: account, resource: resource, weekday: 2)
    break_rule = create(:scheduling_break_rule, account: account, resource: resource, weekday: 2)
    override = create(:scheduling_workday_override, account: account, resource: resource)
    time_off = create(:scheduling_time_off, account: account, resource: resource)
    update_schedule(name: 'Updated specialist')

    expect(response).to have_http_status(:ok)
    expect(resource.work_rules.reload.pluck(:id)).to eq([work_rule.id])
    expect(resource.break_rules.reload.pluck(:id)).to eq([break_rule.id])
    expect(resource.workday_overrides.pluck(:id)).to eq([override.id])
    expect(resource.time_offs.pluck(:id)).to eq([time_off.id])
  end

  it 'cannot modify a specialist from a different account' do
    foreign_resource = create(:scheduling_resource)
    patch "/api/v1/accounts/#{account.id}/scheduling/resources/#{foreign_resource.id}",
          params: { inherit_working_hours_from_account: false, work_rules: [] }, headers: headers, as: :json

    expect(response).to have_http_status(:not_found)
  end

  it 'does not bypass the archived specialist boundary through nested rule sets' do
    rule = create(:scheduling_work_rule, account: account, resource: resource)
    resource.archive_from_scheduling!
    update_schedule(work_rules: [])

    expect(response).to have_http_status(:not_found)
    expect(resource.work_rules.reload.pluck(:id)).to eq([rule.id])
  end

  it 'keeps provider-owned specialists read-only when profile and schedule fields are mixed' do
    resource.update!(custom_attributes: { medelement_specialist_code: 'provider-only' })
    update_schedule(specialty: 'Updated specialty', work_rules: [])

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body['code']).to eq('RESOURCE_READ_ONLY')
  end
end
