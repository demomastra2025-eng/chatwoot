require 'rails_helper'

RSpec.describe 'CRM Task Results Reports API', type: :request do
  let(:account) { create(:account, settings: { 'workspace_timezone' => 'Asia/Almaty' }) }
  let(:viewer) { create(:user, :administrator, account: account) }
  let(:headers) { viewer.create_new_auth_token }
  let(:aggregate_path) { "/api/v1/accounts/#{account.id}/crm/reports/task_results" }
  let(:details_path) { "/api/v1/accounts/#{account.id}/crm/reports/task_result_details" }
  let(:report_params) { { from_date: '2026-09-01', to_date: '2026-09-30', as_of_date: '2026-10-01' } }
  let(:status) { create(:crm_task_status, account: account) }
  let(:task_type) { create(:crm_task_type, account: account, code: 'call') }
  let(:outcome) { create(:crm_task_outcome, account: account, task_type: task_type, code: 'answered') }

  before do
    account.enable_features!('crm_deals', 'crm_tasks')
  end

  def create_result_event(task:, type: 'completed', at: Time.utc(2026, 9, 15, 12), snapshot: {})
    terminal_key = type == 'completed' ? 'completed_at' : 'cancelled_at'
    create(
      :crm_event,
      account: task.account,
      eventable: task,
      event_type: "task_#{type}",
      created_at: at,
      after_data: {
        terminal_key => at.iso8601,
        'all_day' => false,
        'due_at' => (at + 1.hour).iso8601
      }.merge(snapshot)
    )
  end

  def exact_snapshot
    { 'task_type_id' => task_type.id, 'task_outcome_id' => outcome.id, 'outcome' => outcome.code }
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

  it 'returns matching aggregate and paginated drill-down with explicit definitions and one fingerprint' do
    task = create(:crm_task, account: account, status: status, task_type: task_type, task_outcome: outcome)
    event = create_result_event(task: task, snapshot: exact_snapshot)

    get aggregate_path, params: report_params, headers: headers, as: :json
    aggregate = response.parsed_body
    expect(response).to have_http_status(:ok)

    get details_path, params: report_params.merge(page: 1, per_page: 1), headers: headers, as: :json
    details = response.parsed_body

    expect(details.dig('meta', 'total_count')).to eq(1)
    expect(aggregate.dig('payload', 'rows')).to contain_exactly(
      include(
        'lifecycle_type' => 'completed',
        'occurrence_count' => 1,
        'task_type' => include('id' => task_type.id, 'reliability' => 'exact'),
        'task_outcome' => include('id' => outcome.id, 'reliability' => 'exact')
      )
    )
    expect(details.dig('payload', 'rows')).to contain_exactly(
      include(
        'lifecycle_event_id' => event.id,
        'task_id' => task.id,
        'reliability' => 'exact',
        'terminal_responsibility' => include(
          'assignee' => include('state' => 'unknown'),
          'team' => include('state' => 'unknown')
        ),
        'action_actor' => include('event' => include('type' => 'User'))
      )
    )
    expect(aggregate.dig('meta', 'query_fingerprint')).to eq(details.dig('meta', 'query_fingerprint'))
    expect(aggregate['meta']).to include(
      'source' => 'crm_events.task_terminal_catalog_snapshots',
      'definition_version' => 2,
      'cohort_definition' => 'terminal_lifecycle_occurrences_in_window_observed_by_as_of',
      'catalog_label_definition' => 'current_catalog_projection_not_historical_name_or_code_snapshot'
    )
  end

  it 'uses the Task feature gate independently from Deal reports' do
    account.disable_features!('crm_deals')

    get aggregate_path, params: report_params, headers: headers, as: :json

    expect(response).to have_http_status(:ok)
  end

  it 'applies Task view and view_reports intersection to aggregate and drill-down' do
    other_user = create(:user, account: account)
    team = create(:team, account: account)
    create(:team_member, team: team, user: viewer)
    own_task = create(:crm_task, account: account, status: status, task_type: task_type, assignee: viewer)
    team_task = create(:crm_task, account: account, status: status, task_type: task_type, assignee: other_user, team: team)
    hidden_task = create(:crm_task, account: account, status: status, task_type: task_type, assignee: other_user)
    [own_task, team_task, hidden_task].each { |task| create_result_event(task: task, snapshot: exact_snapshot) }
    enable_enforced_access!

    set_task_scope('view', 'own')
    set_task_scope('view_reports', 'all')
    get details_path, params: report_params, headers: headers, as: :json
    expect(response.parsed_body.dig('payload', 'rows').pluck('task_id')).to contain_exactly(own_task.id)

    set_task_scope('view', 'all')
    set_task_scope('view_reports', 'team')
    get aggregate_path, params: report_params, headers: headers, as: :json
    expect(response.parsed_body.dig('payload', 'rows').sum { |row| row['occurrence_count'] }).to eq(2)

    set_task_scope('view_reports', 'none')
    get details_path, params: report_params, headers: headers, as: :json
    expect(response).to have_http_status(:unauthorized)
  end

  it 'does not leak hidden or foreign Task facts and requires authentication' do
    visible = create(:crm_task, account: account, status: status, task_type: task_type, assignee: viewer)
    hidden_owner = create(:user, account: account)
    hidden = create(:crm_task, account: account, status: status, task_type: task_type, assignee: hidden_owner)
    create_result_event(task: visible, snapshot: exact_snapshot)
    create_result_event(task: hidden, snapshot: exact_snapshot)

    foreign_account = create(:account)
    foreign_status = create(:crm_task_status, account: foreign_account)
    foreign_type = create(:crm_task_type, account: foreign_account)
    foreign_outcome = create(:crm_task_outcome, account: foreign_account, task_type: foreign_type)
    foreign_task = create(:crm_task, account: foreign_account, status: foreign_status, task_type: foreign_type)
    create_result_event(
      task: foreign_task,
      snapshot: { 'task_type_id' => foreign_type.id, 'task_outcome_id' => foreign_outcome.id, 'outcome' => foreign_outcome.code }
    )

    enable_enforced_access!
    set_task_scope('view', 'own')
    set_task_scope('view_reports', 'all')
    get aggregate_path, params: report_params, headers: headers, as: :json

    expect(response.parsed_body.dig('payload', 'rows').sum { |row| row['occurrence_count'] }).to eq(1)

    get aggregate_path, params: report_params, as: :json
    expect(response).to have_http_status(:unauthorized)
  end

  it 'validates catalog filters inside the account and preserves aggregate/details filter parity' do
    task = create(:crm_task, account: account, status: status, task_type: task_type, task_outcome: outcome)
    create_result_event(task: task, snapshot: exact_snapshot)
    foreign_type = create(:crm_task_type, account: create(:account))
    filters = report_params.merge(task_type_id: task_type.id, task_outcome_id: outcome.id, reliability: 'exact')

    get aggregate_path, params: filters, headers: headers, as: :json
    aggregate = response.parsed_body
    get details_path, params: filters, headers: headers, as: :json
    details = response.parsed_body

    expect(aggregate.dig('payload', 'rows').sum { |row| row['occurrence_count'] }).to eq(1)
    expect(details.dig('meta', 'total_count')).to eq(1)
    expect(aggregate.dig('meta', 'query_fingerprint')).to eq(details.dig('meta', 'query_fingerprint'))

    get aggregate_path, params: report_params.merge(task_type_id: foreign_type.id), headers: headers, as: :json
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body).to include('code' => 'INVALID_REPORT_QUERY', 'error' => 'task_type_id is invalid')
  end
end
