require 'rails_helper'

RSpec.describe 'CRM Deal Workload Reports API', type: :request do
  let(:account) { create(:account, settings: { 'workspace_timezone' => 'Asia/Almaty' }) }
  let(:viewer) { create(:user, :administrator, account: account) }
  let(:headers) { viewer.create_new_auth_token }
  let(:aggregate_path) { "/api/v1/accounts/#{account.id}/crm/reports/deal_workload" }
  let(:details_path) { "/api/v1/accounts/#{account.id}/crm/reports/deal_workload_details" }
  let(:pipeline) { create(:crm_pipeline, account: account) }
  let(:stage) { create(:crm_stage, account: account, pipeline: pipeline) }

  before { account.enable_features!('crm_deals') }

  def enable_enforced_access!
    AccessControl::LegacyRoleAssigner.call(account: account, apply: true)
    AccessControl::ModeTransition.call(account: account, to: :shadow)
    AccessControl::ModeTransition.call(account: account, to: :enforced)
  end

  def set_scope(capability, scope)
    grants = viewer.account_users.find_by!(account: account).access_role.grants
    grant = grants.find_or_initialize_by(account: account, resource: 'deals', capability: capability)
    grant.update!(access_scope: scope)
  end

  it 'returns independent dimensions, metadata, and matching bucket details' do
    owner = create(:user, account: account, name: 'Owner')
    team = create(:team, account: account, name: 'Team')
    actionable = create(:crm_deal, account: account, pipeline: pipeline, stage: stage, owner: owner, team: team)
    waiting = create(:crm_deal, account: account, pipeline: pipeline, stage: stage, owner: owner, team: team,
                                waiting_until: 1.hour.ago, waiting_started_at: 1.day.ago, waiting_reason: 'Expired')

    get aggregate_path, headers: headers, as: :json
    aggregate = response.parsed_body
    get details_path, params: { dimension: 'owner', owner_id: owner.id }, headers: headers, as: :json
    details = response.parsed_body

    expect(response).to have_http_status(:ok)
    expect(aggregate.dig('payload', 'rows').pluck('dimension')).to contain_exactly('owner', 'team')
    expect(aggregate.dig('payload', 'rows')).to all(include('open_count' => 2, 'waiting_count' => 1, 'actionable_count' => 1))
    expect(details.dig('payload', 'rows').pluck('deal_id')).to eq([actionable.id, waiting.id])
    expect(details.dig('meta', 'total_count')).to eq(2)
    expect(details.dig('payload', 'rows').pluck('state')).to contain_exactly('actionable', 'waiting')
    expect(aggregate['meta']).to include(
      'metric_kind' => 'current_snapshot',
      'reliability' => 'exact',
      'timezone' => 'Asia/Almaty',
      'historical_attribution' => 'unknown_not_supported',
      'combination_definition' => 'owner_and_team_dimensions_must_not_be_summed'
    )
  end

  it 'applies Deal view intersect view_reports for own, team, all, and none' do
    teammate = create(:user, account: account)
    outsider = create(:user, account: account)
    team = create(:team, account: account)
    create(:team_member, team: team, user: viewer)
    own_deal = create(:crm_deal, account: account, pipeline: pipeline, stage: stage, owner: viewer)
    team_deal = create(:crm_deal, account: account, pipeline: pipeline, stage: stage, owner: teammate, team: team)
    hidden_deal = create(:crm_deal, account: account, pipeline: pipeline, stage: stage, owner: outsider)
    enable_enforced_access!

    set_scope('view', 'own')
    set_scope('view_reports', 'all')
    get details_path, params: { dimension: 'owner' }, headers: headers, as: :json
    expect(response.parsed_body.dig('payload', 'rows').pluck('deal_id')).to contain_exactly(own_deal.id)

    set_scope('view', 'all')
    set_scope('view_reports', 'team')
    get details_path, params: { dimension: 'owner' }, headers: headers, as: :json
    expect(response.parsed_body.dig('payload', 'rows').pluck('deal_id')).to contain_exactly(own_deal.id, team_deal.id)

    set_scope('view_reports', 'all')
    get details_path, params: { dimension: 'owner' }, headers: headers, as: :json
    expect(response.parsed_body.dig('payload', 'rows').pluck('deal_id')).to contain_exactly(own_deal.id, team_deal.id, hidden_deal.id)

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

  it 'preserves legacy report intersection and denies a viewer without report permission' do
    reporting_user = create(:user, account: account)
    reporting_role = create(:custom_role, account: account, permissions: ['report_manage'])
    reporting_user.account_users.find_by!(account: account).update!(custom_role: reporting_role)
    create(:crm_deal, account: account, pipeline: pipeline, stage: stage)

    get aggregate_path, headers: reporting_user.create_new_auth_token, as: :json
    expect(response).to have_http_status(:ok)

    plain_agent = create(:user, account: account)
    get aggregate_path, headers: plain_agent.create_new_auth_token, as: :json
    expect(response).to have_http_status(:unauthorized)
  end

  it 'validates feature, authentication, historical input, dimensions, and tenant filters' do
    get aggregate_path, as: :json
    expect(response).to have_http_status(:unauthorized)

    account.disable_features!('crm_deals')
    get aggregate_path, headers: headers, as: :json
    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body['code']).to eq('FEATURE_DISABLED')
    account.enable_features!('crm_deals')

    get aggregate_path, params: { as_of: Time.current.iso8601 }, headers: headers, as: :json
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body).to include('code' => 'INVALID_REPORT_QUERY', 'error' => 'as_of is not supported for current snapshots')

    foreign_team = create(:team, account: create(:account))
    get aggregate_path, params: { dimension: 'team', team_id: foreign_team.id }, headers: headers, as: :json
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body['error']).to eq('team_id is invalid')
  end

  it 'does not expose hidden account attribution through filter validation or visible zero' do
    hidden_owner = create(:user, account: account)
    create(:crm_deal, account: account, pipeline: pipeline, stage: stage, owner: hidden_owner)
    enable_enforced_access!
    set_scope('view', 'own')
    set_scope('view_reports', 'all')

    get aggregate_path,
        params: { dimension: 'owner', owner_id: hidden_owner.id },
        headers: headers,
        as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body).to include('code' => 'INVALID_REPORT_QUERY', 'error' => 'owner_id is invalid')
  end
end
