require 'rails_helper'

RSpec.describe 'CRM Task Lifecycle Reports API', type: :request do
  let(:account) { create(:account, settings: { 'workspace_timezone' => 'Asia/Almaty' }) }
  let(:viewer) { create(:user, :administrator, account: account) }
  let(:headers) { viewer.create_new_auth_token }
  let(:aggregate_path) { "/api/v1/accounts/#{account.id}/crm/reports/task_lifecycle" }
  let(:details_path) { "/api/v1/accounts/#{account.id}/crm/reports/task_lifecycle_details" }
  let(:report_params) { { from_date: '2026-09-01', to_date: '2026-09-30', as_of_date: '2026-10-01' } }
  let(:status) { create(:crm_task_status, account: account) }

  before do
    account.enable_features!('crm_deals', 'crm_tasks')
  end

  def create_terminal_event(task:, type: 'completed', at: Time.utc(2026, 9, 15, 12), due_at: Time.utc(2026, 9, 15, 11))
    create(
      :crm_event,
      account: task.account,
      eventable: task,
      event_type: "task_#{type}",
      created_at: at,
      after_data: { 'all_day' => false, 'due_at' => due_at.iso8601, "#{type}_at" => at.iso8601 }
    )
  end

  def enable_enforced_access!
    AccessControl::LegacyRoleAssigner.call(account: account, apply: true)
    AccessControl::ModeTransition.call(account: account, to: :shadow)
    AccessControl::ModeTransition.call(account: account, to: :enforced)
  end

  def set_task_scope(capability, scope)
    viewer.account_users.find_by!(account: account).access_role.grants
          .find_by!(resource: 'tasks', capability: capability)
          .update!(access_scope: scope)
  end

  it 'returns matching aggregate and paginated immutable drill-down with one fingerprint' do
    task = create(:crm_task, account: account, status: status, title: 'Must not leak')
    event = create_terminal_event(task: task)

    get aggregate_path, params: report_params, headers: headers, as: :json
    aggregate = response.parsed_body
    expect(response).to have_http_status(:ok)

    get details_path, params: report_params.merge(page: 1, per_page: 1), headers: headers, as: :json
    details = response.parsed_body

    expect(details.dig('meta', 'total_count')).to eq(1)
    expect(aggregate.dig('payload', 'rows')).to contain_exactly(
      include('lifecycle_type' => 'completed', 'lifecycle_count' => 1, 'overdue_count' => 1)
    )
    expect(details.dig('payload', 'rows')).to contain_exactly(
      include(
        'lifecycle_event_id' => event.id,
        'task_id' => task.id,
        'lifecycle_type' => 'completed',
        'deadline_state' => 'overdue'
      )
    )
    expect(details.to_json).not_to include('Must not leak')
    expect(aggregate.dig('meta', 'query_fingerprint')).to eq(details.dig('meta', 'query_fingerprint'))
    expect(aggregate['meta']).to include(
      'source' => 'crm_events.task_terminal_lifecycle',
      'definition_version' => 1,
      'cohort_definition' => 'terminal_lifecycle_occurrences_in_window_observed_by_as_of'
    )
  end

  it 'uses the Task feature gate independently from Deal reports' do
    account.disable_features!('crm_deals')

    get aggregate_path, params: report_params, headers: headers, as: :json

    expect(response).to have_http_status(:ok)
  end

  it 'applies Task view and view_reports intersection before aggregate and drill-down' do
    other_user = create(:user, account: account)
    team = create(:team, account: account)
    create(:team_member, team: team, user: viewer)
    own_task = create(:crm_task, account: account, status: status, assignee: viewer)
    team_task = create(:crm_task, account: account, status: status, assignee: other_user, team: team)
    hidden_task = create(:crm_task, account: account, status: status, assignee: other_user)
    [own_task, team_task, hidden_task].each { |task| create_terminal_event(task: task) }
    enable_enforced_access!

    set_task_scope('view', 'own')
    set_task_scope('view_reports', 'all')
    get details_path, params: report_params, headers: headers, as: :json
    expect(response.parsed_body.dig('payload', 'rows').pluck('task_id')).to contain_exactly(own_task.id)

    set_task_scope('view', 'all')
    set_task_scope('view_reports', 'team')
    get aggregate_path, params: report_params, headers: headers, as: :json
    expect(response.parsed_body.dig('payload', 'rows').sum { |row| row['lifecycle_count'] }).to eq(2)

    set_task_scope('view_reports', 'none')
    get details_path, params: report_params, headers: headers, as: :json
    expect(response).to have_http_status(:unauthorized)
  end

  it 'does not let a legacy report-only role bypass Task view scope' do
    task = create(:crm_task, account: account, status: status)
    create_terminal_event(task: task)
    report_user = create(:user, account: account)
    custom_role = create(:custom_role, account: account, permissions: %w[report_manage])
    report_user.account_users.find_by!(account: account).update!(custom_role: custom_role)

    get aggregate_path, params: report_params, headers: report_user.create_new_auth_token, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('payload', 'rows')).to be_empty
  end

  it 'does not leak hidden or foreign Task facts and requires authentication' do
    visible = create(:crm_task, account: account, status: status, assignee: viewer)
    hidden_owner = create(:user, account: account)
    hidden = create(:crm_task, account: account, status: status, assignee: hidden_owner)
    create_terminal_event(task: visible)
    create_terminal_event(task: hidden)

    foreign_account = create(:account)
    foreign_status = create(:crm_task_status, account: foreign_account)
    foreign_task = create(:crm_task, account: foreign_account, status: foreign_status)
    create_terminal_event(task: foreign_task)

    enable_enforced_access!
    set_task_scope('view', 'own')
    set_task_scope('view_reports', 'all')
    get aggregate_path, params: report_params, headers: headers, as: :json

    expect(response.parsed_body.dig('payload', 'rows').sum { |row| row['lifecycle_count'] }).to eq(1)

    get aggregate_path, params: report_params, as: :json
    expect(response).to have_http_status(:unauthorized)
  end

  it 'returns the CRM validation envelope for invalid lifecycle queries' do
    get aggregate_path, params: report_params.except(:as_of_date), headers: headers, as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body).to include(
      'code' => 'INVALID_REPORT_QUERY',
      'error' => 'as_of_date is required'
    )
  end
end
