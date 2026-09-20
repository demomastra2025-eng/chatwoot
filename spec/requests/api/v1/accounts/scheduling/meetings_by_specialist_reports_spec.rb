require 'rails_helper'

RSpec.describe 'Scheduling Meetings By Specialist Reports API', type: :request do
  let(:account) { create(:account, settings: { 'workspace_timezone' => 'Asia/Almaty' }) }
  let(:viewer) { create(:user, :administrator, account: account) }
  let(:headers) { viewer.create_new_auth_token }
  let(:aggregate_path) { "/api/v1/accounts/#{account.id}/scheduling/reports/meetings_by_specialist" }
  let(:details_path) { "/api/v1/accounts/#{account.id}/scheduling/reports/meetings_by_specialist_details" }
  let(:window) { { from_local: '2026-01-01T00:00:00', to_local: '2026-02-01T00:00:00' } }
  let(:starts_at) { ActiveSupport::TimeZone['Asia/Almaty'].local(2026, 1, 10, 10) }

  before do
    account.enable_features!('scheduling')
  end

  def create_appointment(resource:, **attributes)
    create(
      :scheduling_appointment,
      account: account,
      resource: resource,
      starts_at: starts_at,
      ends_at: starts_at + 30.minutes,
      **attributes
    )
  end

  def enable_enforced_access!
    AccessControl::LegacyRoleAssigner.call(account: account, apply: true)
    AccessControl::ModeTransition.call(account: account, to: :shadow)
    AccessControl::ModeTransition.call(account: account, to: :enforced)
  end

  def set_scope(capability, scope)
    grants = viewer.account_users.find_by!(account: account).access_role.grants
    grant = grants.find_or_initialize_by(account: account, resource: 'appointments', capability: capability)
    grant.update!(access_scope: scope)
  end

  it 'returns aggregate and paginated detail parity with one deterministic fingerprint' do
    first_resource = create(:scheduling_resource, account: account, name: 'A specialist')
    second_resource = create(:scheduling_resource, account: account, name: 'B specialist', user: viewer)
    first = create_appointment(resource: first_resource, status: 'confirmed')
    second = create_appointment(resource: second_resource, status: 'completed')
    foreign_account = create(:account)
    create(
      :scheduling_appointment,
      account: foreign_account,
      resource: create(:scheduling_resource, account: foreign_account),
      starts_at: starts_at,
      ends_at: starts_at + 30.minutes
    )

    get aggregate_path, params: window, headers: headers, as: :json
    aggregate = response.parsed_body
    expect(response).to have_http_status(:ok)

    get details_path, params: window.merge(page: 1, per_page: 1), headers: headers, as: :json
    first_page = response.parsed_body
    get details_path, params: window.merge(page: 2, per_page: 1), headers: headers, as: :json
    second_page = response.parsed_body

    aggregate_counts = [
      aggregate.dig('meta', 'total_count'), aggregate.dig('payload', 'rows').sum { |row| row['total_count'] }
    ]
    expect(aggregate_counts).to eq([2, 2])
    expect(first_page.dig('payload', 'rows').pluck('appointment_id')).to eq([first.id])
    expect(second_page.dig('payload', 'rows').pluck('appointment_id')).to eq([second.id])
    expect(first_page.dig('meta', 'total_count')).to eq(2)
    expect(aggregate.dig('meta', 'query_fingerprint')).to eq(first_page.dig('meta', 'query_fingerprint'))
    expect(aggregate['meta']).to include(
      'metric_kind' => 'current_projection',
      'reliability' => 'exact_current_snapshot',
      'timezone' => 'Asia/Almaty',
      'from' => '2025-12-31T19:00:00.000000Z',
      'to' => '2026-01-31T19:00:00.000000Z',
      'definition_version' => 1,
      'reliability_boundary' => 'historical_as_of_attribution_unknown_without_immutable_appointment_facts'
    )
  end

  it 'intersects view and view_reports using persisted appointment Team, not current Resource membership' do
    persisted_team = create(:team, account: account)
    second_member_team = create(:team, account: account)
    current_resource_team = create(:team, account: account)
    create(:team_member, team: persisted_team, user: viewer)
    own_resource = create(:scheduling_resource, account: account, user: viewer)
    team_resource = create(:scheduling_resource, account: account, team: current_resource_team)
    hidden_resource = create(:scheduling_resource, account: account)
    own = create_appointment(resource: own_resource)
    team = create_appointment(resource: team_resource, team: persisted_team)
    hidden = create_appointment(resource: hidden_resource)
    create(:team_member, team: second_member_team, user: viewer)
    enable_enforced_access!

    set_scope('view', 'all')
    set_scope('view_reports', 'team')
    get details_path, params: window, headers: headers, as: :json

    team_details = response.parsed_body
    ids = team_details.dig('payload', 'rows').pluck('appointment_id')
    expect(ids).to contain_exactly(own.id, team.id)
    expect(ids).not_to include(hidden.id)

    get aggregate_path, params: window, headers: headers, as: :json
    expect(response.parsed_body.dig('meta', 'query_fingerprint')).to eq(team_details.dig('meta', 'query_fingerprint'))

    set_scope('view', 'none')
    set_scope('view_reports', 'all')
    get aggregate_path, params: window, headers: headers, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('meta', 'total_count')).to eq(0)

    set_scope('view_reports', 'none')
    get aggregate_path, params: window, headers: headers, as: :json
    expect(response).to have_http_status(:unauthorized)
  end

  it 'preserves legacy report-only access while requiring report permission' do
    report_viewer = create(:user, account: account)
    role = create(:custom_role, account: account, permissions: ['report_manage'])
    report_viewer.account_users.find_by!(account: account).update!(custom_role: role)
    appointment = create_appointment(resource: create(:scheduling_resource, account: account))

    get details_path, params: window, headers: report_viewer.create_new_auth_token, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('payload', 'rows').pluck('appointment_id')).to eq([appointment.id])
  end

  it 'applies tenant-safe resource, Team, Service, status, and half-open filters' do
    resource = create(:scheduling_resource, account: account)
    team = create(:team, account: account)
    service = create(:scheduling_service, account: account)
    matching = create_appointment(resource: resource, team: team, service: service, status: 'confirmed')
    create_appointment(resource: resource, team: team, service: service, status: 'cancelled')
    filters = window.merge(resource_id: resource.id, team_id: team.id, service_id: service.id, status: 'confirmed')

    get aggregate_path, params: filters, headers: headers, as: :json
    aggregate = response.parsed_body
    get details_path, params: filters, headers: headers, as: :json
    details = response.parsed_body

    expect(aggregate.dig('meta', 'total_count')).to eq(1)
    expect(details.dig('payload', 'rows').pluck('appointment_id')).to eq([matching.id])
    expect(aggregate.dig('meta', 'query_fingerprint')).to eq(details.dig('meta', 'query_fingerprint'))

    foreign_team = create(:team, account: create(:account))
    get aggregate_path, params: window.merge(team_id: foreign_team.id), headers: headers, as: :json
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body).to include('code' => 'INVALID_REPORT_QUERY', 'error' => 'team_id is invalid')
  end

  it 'reflects reschedule, status, and Resource edits only in later current projections' do
    original_resource = create(:scheduling_resource, account: account)
    new_resource = create(:scheduling_resource, account: account)
    appointment = create_appointment(resource: original_resource, status: 'scheduled')

    get aggregate_path, params: window, headers: headers, as: :json
    before_projection = response.parsed_body
    appointment.update!(resource: new_resource, status: 'completed', starts_at: starts_at + 1.day, ends_at: starts_at + 1.day + 45.minutes)
    get aggregate_path, params: window, headers: headers, as: :json
    after_projection = response.parsed_body

    expect(before_projection.dig('payload', 'rows', 0, 'specialist', 'id')).to eq(original_resource.id)
    expect(before_projection.dig('payload', 'rows', 0, 'status_counts', 'scheduled')).to eq(1)
    expect(after_projection.dig('payload', 'rows', 0, 'specialist', 'id')).to eq(new_resource.id)
    expect(after_projection.dig('payload', 'rows', 0, 'status_counts', 'completed')).to eq(1)
    expect(after_projection.dig('payload', 'rows', 0, 'scheduled_duration', 'seconds')).to eq(2_700)
  end

  it 'requires authentication, Scheduling feature, bounded local window, and rejects historical as_of' do
    get aggregate_path, params: window, as: :json
    expect(response).to have_http_status(:unauthorized)

    account.disable_features!('scheduling')
    get aggregate_path, params: window, headers: headers, as: :json
    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body['code']).to eq('FEATURE_DISABLED')

    account.enable_features!('scheduling')
    get aggregate_path, params: {}, headers: headers, as: :json
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body).to include('code' => 'INVALID_REPORT_QUERY', 'error' => 'from_local is required')

    get aggregate_path, params: window.merge(as_of: '2025-01-01T00:00:00Z'), headers: headers, as: :json
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body['error']).to eq('as_of is not supported for current projections')
  end
end
