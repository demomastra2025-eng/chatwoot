require 'rails_helper'

RSpec.describe 'CommunicationThread Workload Reports API', type: :request do
  let(:account) { create(:account, settings: { 'workspace_timezone' => 'Asia/Almaty' }) }
  let(:viewer) { create(:user, :administrator, account: account) }
  let(:headers) { viewer.create_new_auth_token }
  let(:aggregate_path) { "/api/v1/accounts/#{account.id}/communication_threads/reports/workload" }
  let(:details_path) { "/api/v1/accounts/#{account.id}/communication_threads/reports/workload_details" }

  before { account.enable_features!('communication_threads') }

  def enable_enforced_access!
    AccessControl::LegacyRoleAssigner.call(account: account, apply: true)
    AccessControl::ModeTransition.call(account: account, to: :shadow)
    AccessControl::ModeTransition.call(account: account, to: :enforced)
  end

  def set_scope(capability, scope)
    grants = viewer.account_users.find_by!(account: account).access_role.grants
    grant = grants.find_or_initialize_by(account: account, resource: 'conversations', capability: capability)
    grant.update!(access_scope: scope)
  end

  it 'returns current owner workload and matching details without historical claims' do
    owner = create(:user, account: account, name: 'Owner')
    team = create(:team, account: account, name: 'Queue')
    open_thread = create(:communication_thread, account: account, assignee: owner, team: team, status: :open,
                                                priority: :high, unread_count: 2)
    pending_thread = create(:communication_thread, account: account, assignee: owner, team: team, status: :pending,
                                                   priority: nil, unread_count: 0)

    get aggregate_path, headers: headers, as: :json
    aggregate = response.parsed_body
    get details_path, params: { dimension: 'owner', assignee_id: owner.id }, headers: headers, as: :json
    details = response.parsed_body

    expect(response).to have_http_status(:ok)
    expect(aggregate.dig('payload', 'rows').pluck('dimension')).to contain_exactly('owner', 'team')
    expect(aggregate.dig('payload', 'rows')).to all(include('unresolved_count' => 2, 'open_count' => 1, 'pending_count' => 1))
    expect(details.dig('payload', 'rows').pluck('communication_thread_id')).to eq([open_thread.id, pending_thread.id])
    expect(details.dig('meta', 'total_count')).to eq(2)
    expect(aggregate['meta']).to include(
      'metric_kind' => 'current_snapshot',
      'reliability' => 'exact',
      'historical_attribution' => 'unknown_not_supported',
      'participant_definition' => 'participant_membership_never_grants_owner_workload_credit',
      'sla_state' => 'not_configured_not_supported'
    )
  end

  it 'applies canonical owner-only view intersect view_reports for own, team, all, and none' do
    teammate = create(:user, account: account)
    outsider = create(:user, account: account)
    team = create(:team, account: account)
    create(:team_member, team: team, user: viewer)
    own_thread = create(:communication_thread, account: account, assignee: viewer)
    team_thread = create(:communication_thread, account: account, assignee: teammate, team: team)
    hidden_thread = create(:communication_thread, account: account, assignee: outsider)
    participant_only = create(:communication_thread, account: account, assignee: outsider)
    create(:communication_thread_participant, account: account, communication_thread: participant_only, user: viewer)
    enable_enforced_access!

    set_scope('view', 'own')
    set_scope('view_reports', 'all')
    get details_path, params: { dimension: 'owner' }, headers: headers, as: :json
    expect(response.parsed_body.dig('payload', 'rows').pluck('communication_thread_id')).to contain_exactly(own_thread.id)

    set_scope('view', 'all')
    set_scope('view_reports', 'team')
    get details_path, params: { dimension: 'owner' }, headers: headers, as: :json
    expect(response.parsed_body.dig('payload', 'rows').pluck('communication_thread_id')).to contain_exactly(own_thread.id, team_thread.id)

    set_scope('view_reports', 'all')
    get details_path, params: { dimension: 'owner' }, headers: headers, as: :json
    expect(response.parsed_body.dig('payload', 'rows').pluck('communication_thread_id'))
      .to contain_exactly(own_thread.id, team_thread.id, hidden_thread.id, participant_only.id)

    set_scope('view', 'none')
    get aggregate_path, headers: headers, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('payload', 'rows')).to be_empty
    expect(response.parsed_body.dig('meta', 'total_count')).to eq(0)

    set_scope('view', 'all')
    set_scope('view_reports', 'none')
    get aggregate_path, headers: headers, as: :json
    expect(response).to have_http_status(:unauthorized)
  end

  it 'preserves legacy report authorization while denying plain agents' do
    reporting_user = create(:user, account: account)
    reporting_role = create(:custom_role, account: account, permissions: ['report_manage'])
    reporting_user.account_users.find_by!(account: account).update!(custom_role: reporting_role)
    create(:communication_thread, account: account)

    get aggregate_path, headers: reporting_user.create_new_auth_token, as: :json
    expect(response).to have_http_status(:ok)

    plain_agent = create(:user, account: account)
    get aggregate_path, headers: plain_agent.create_new_auth_token, as: :json
    expect(response).to have_http_status(:unauthorized)
  end

  it 'enforces authentication and the communication threads feature' do
    get aggregate_path, as: :json
    expect(response).to have_http_status(:unauthorized)

    account.disable_features!('communication_threads')
    get aggregate_path, headers: headers, as: :json
    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body['code']).to eq('FEATURE_DISABLED')
    account.enable_features!('communication_threads')
  end

  it 'rejects historical parameters and foreign tenant filters' do
    get aggregate_path, params: { as_of: Time.current.iso8601 }, headers: headers, as: :json
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body).to include('code' => 'INVALID_REPORT_QUERY', 'error' => 'as_of is not supported for current snapshots')

    get aggregate_path, params: { since: 1.day.ago.iso8601 }, headers: headers, as: :json
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body).to include('code' => 'INVALID_REPORT_QUERY', 'error' => 'since is not supported for current snapshots')

    foreign_team = create(:team, account: create(:account))
    get aggregate_path, params: { dimension: 'team', team_id: foreign_team.id }, headers: headers, as: :json
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body['error']).to eq('team_id is invalid')
  end

  it 'does not expose hidden attribution through filter validation or visible zero' do
    hidden_owner = create(:user, account: account)
    create(:communication_thread, account: account, assignee: hidden_owner)
    enable_enforced_access!
    set_scope('view', 'own')
    set_scope('view_reports', 'all')

    get aggregate_path,
        params: { dimension: 'owner', assignee_id: hidden_owner.id },
        headers: headers,
        as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body).to include('code' => 'INVALID_REPORT_QUERY', 'error' => 'assignee_id is invalid')
  end
end
