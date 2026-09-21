require 'rails_helper'

RSpec.describe 'CRM Task Workload Reports API', type: :request do
  let(:account) { create(:account, settings: { 'workspace_timezone' => 'Asia/Almaty' }) }
  let(:viewer) { create(:user, :administrator, account: account) }
  let(:headers) { viewer.create_new_auth_token }
  let(:aggregate_path) { "/api/v1/accounts/#{account.id}/crm/reports/task_workload" }
  let(:details_path) { "/api/v1/accounts/#{account.id}/crm/reports/task_workload_details" }
  let(:status) { create(:crm_task_status, account: account, category: 'open') }
  let(:task_type) { create(:crm_task_type, account: account) }

  before { account.enable_features!('crm_tasks') }

  def create_task(**attributes)
    create(:crm_task, { account: account, status: status, task_type: task_type }.merge(attributes))
  end

  def enable_enforced_access!
    AccessControl::LegacyRoleAssigner.call(account: account, apply: true)
    AccessControl::ModeTransition.call(account: account, to: :shadow)
    AccessControl::ModeTransition.call(account: account, to: :enforced)
  end

  def set_scope(capability, scope)
    grants = viewer.account_users.find_by!(account: account).access_role.grants
    grant = grants.find_or_initialize_by(account: account, resource: 'tasks', capability: capability)
    grant.update!(access_scope: scope)
  end

  it 'returns independent dimensions, metadata, and matching bucket details' do
    assignee = create(:user, account: account, name: 'Assignee')
    team = create(:team, account: account, name: 'Team')
    scheduled = create_task(assignee: assignee, team: team, due_at: 1.day.from_now)
    unscheduled = create_task(assignee: assignee, team: team)

    get aggregate_path, headers: headers, as: :json
    aggregate = response.parsed_body
    get details_path, params: { dimension: 'assignee', assignee_id: assignee.id }, headers: headers, as: :json
    details = response.parsed_body

    expect(response).to have_http_status(:ok)
    expect(aggregate.dig('payload', 'rows').pluck('dimension')).to contain_exactly('assignee', 'team')
    expect(aggregate.dig('payload', 'rows')).to all(include('open_count' => 2, 'future_count' => 1, 'unscheduled_count' => 1))
    expect(details.dig('payload', 'rows').pluck('task_id')).to eq([scheduled.id, unscheduled.id])
    expect(details.dig('meta', 'total_count')).to eq(2)
    expect(aggregate['meta']).to include(
      'metric_kind' => 'current_snapshot', 'reliability' => 'exact', 'timezone' => 'Asia/Almaty',
      'historical_attribution' => 'unknown_not_supported',
      'combination_definition' => 'assignee_and_team_dimensions_must_not_be_summed'
    )
  end

  it 'applies Task view intersect view_reports for own, team, all, and none' do
    teammate = create(:user, account: account)
    outsider = create(:user, account: account)
    team = create(:team, account: account)
    create(:team_member, team: team, user: viewer)
    own_task = create_task(assignee: viewer)
    team_task = create_task(assignee: teammate, team: team)
    hidden_task = create_task(assignee: outsider)
    enable_enforced_access!

    set_scope('view', 'own')
    set_scope('view_reports', 'all')
    get details_path, params: { dimension: 'assignee' }, headers: headers, as: :json
    expect(response.parsed_body.dig('payload', 'rows').pluck('task_id')).to contain_exactly(own_task.id)

    set_scope('view', 'all')
    set_scope('view_reports', 'team')
    get details_path, params: { dimension: 'assignee' }, headers: headers, as: :json
    expect(response.parsed_body.dig('payload', 'rows').pluck('task_id')).to contain_exactly(own_task.id, team_task.id)

    set_scope('view_reports', 'all')
    get details_path, params: { dimension: 'assignee' }, headers: headers, as: :json
    expect(response.parsed_body.dig('payload', 'rows').pluck('task_id')).to contain_exactly(own_task.id, team_task.id, hidden_task.id)

    set_scope('view', 'none')
    get aggregate_path, headers: headers, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('meta', 'total_count')).to eq(0)

    set_scope('view', 'all')
    set_scope('view_reports', 'none')
    get aggregate_path, headers: headers, as: :json
    expect(response).to have_http_status(:unauthorized)
  end

  it 'preserves legacy report intersection and denies a viewer without report permission' do
    reporting_user = create(:user, account: account)
    reporting_role = create(:custom_role, account: account, permissions: ['report_manage'])
    reporting_user.account_users.find_by!(account: account).update!(custom_role: reporting_role)
    create_task

    get aggregate_path, headers: reporting_user.create_new_auth_token, as: :json
    expect(response).to have_http_status(:ok)

    plain_agent = create(:user, account: account)
    get aggregate_path, headers: plain_agent.create_new_auth_token, as: :json
    expect(response).to have_http_status(:unauthorized)
  end

  it 'validates authentication, feature gate, history, and tenant filters' do
    get aggregate_path, as: :json
    expect(response).to have_http_status(:unauthorized)

    account.disable_features!('crm_tasks')
    get aggregate_path, headers: headers, as: :json
    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body['code']).to eq('FEATURE_DISABLED')
    account.enable_features!('crm_tasks')

    get aggregate_path, params: { from: 1.day.ago.iso8601 }, headers: headers, as: :json
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body).to include('code' => 'INVALID_REPORT_QUERY', 'error' => 'from is not supported for current snapshots')

    foreign_team = create(:team, account: create(:account))
    get aggregate_path, params: { dimension: 'team', team_id: foreign_team.id }, headers: headers, as: :json
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body['error']).to eq('team_id is invalid')
  end

  it 'does not expose policy-hidden attribution through filter validation or visible zero' do
    hidden_assignee = create(:user, account: account)
    create_task(assignee: hidden_assignee)
    enable_enforced_access!
    set_scope('view', 'own')
    set_scope('view_reports', 'all')

    get aggregate_path, params: { dimension: 'assignee', assignee_id: hidden_assignee.id }, headers: headers, as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body).to include('code' => 'INVALID_REPORT_QUERY', 'error' => 'assignee_id is invalid')
  end
end
