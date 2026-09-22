require 'rails_helper'

RSpec.describe 'CRM Deal Terminal Outcomes Reports API', type: :request do
  let(:account) { create(:account, settings: { 'workspace_timezone' => 'Asia/Almaty' }) }
  let(:viewer) { create(:user, :administrator, account: account) }
  let(:headers) { viewer.create_new_auth_token }
  let(:aggregate_path) { "/api/v1/accounts/#{account.id}/crm/reports/deal_terminal_outcomes" }
  let(:details_path) { "/api/v1/accounts/#{account.id}/crm/reports/deal_terminal_outcomes_details" }
  let(:params) { { from_date: '2026-09-01', to_date: '2026-09-30', as_of_date: '2026-09-30' } }
  let(:pipeline) { create(:crm_pipeline, account: account) }
  let(:won_stage) { create(:crm_stage, account: account, pipeline: pipeline, outcome: 'won') }

  before { account.enable_features!('crm_deals') }

  def enable_enforced_access!
    AccessControl::LegacyRoleAssigner.call(account: account, apply: true)
    AccessControl::ModeTransition.call(account: account, to: :shadow)
    AccessControl::ModeTransition.call(account: account, to: :enforced)
  end

  def set_scope(capability, scope)
    grants = viewer.account_users.find_by!(account: account).access_role.grants
    grants.find_or_initialize_by(account: account, resource: 'deals', capability: capability).update!(access_scope: scope)
  end

  def terminal_visit(deal:, owner: nil, at: Time.utc(2026, 9, 10, 12))
    create(
      :crm_stage_visit,
      account: account,
      deal: deal,
      pipeline: pipeline,
      stage: won_stage,
      stage_outcome: 'won',
      entered_at: at,
      reliable_since: at,
      owner_id_at_terminal: owner&.id,
      terminal_attribution_version: 1
    )
  end

  it 'returns aggregate and matching paginated occurrence details from one contract' do
    owner = create(:user, account: account, name: 'Closer')
    deal = create(:crm_deal, account: account, pipeline: pipeline, stage: won_stage, owner: owner)
    visit = terminal_visit(deal: deal, owner: owner)

    get aggregate_path, params: params.merge(dimension: 'owner', owner_id: owner.id), headers: headers, as: :json
    aggregate = response.parsed_body
    get details_path, params: params.merge(dimension: 'owner', owner_id: owner.id, page: 1, per_page: 1), headers: headers, as: :json
    details = response.parsed_body

    expect(response).to have_http_status(:ok)
    expect(aggregate.dig('payload', 'rows')).to contain_exactly(
      include('dimension' => 'owner', 'outcome' => 'won', 'outcome_count' => 1,
              'attribution' => include('id' => owner.id, 'state' => 'current_catalog_projection'))
    )
    expect(details.dig('payload', 'rows')).to contain_exactly(
      include('stage_visit_id' => visit.id, 'deal_id' => deal.id, 'outcome' => 'won', 'reliability' => 'exact')
    )
    expect(details['meta']).to include('page' => 1, 'per_page' => 1, 'total_count' => 1, 'exact_count' => 1)
    expect(details.dig('meta', 'query_fingerprint')).to eq(aggregate.dig('meta', 'query_fingerprint'))
  end

  it 'applies Deal view intersect view_reports to historical occurrences' do
    own_deal = create(:crm_deal, account: account, pipeline: pipeline, stage: won_stage, owner: viewer)
    teammate = create(:user, account: account)
    outsider = create(:user, account: account)
    team = create(:team, account: account)
    create(:team_member, team: team, user: viewer)
    team_deal = create(:crm_deal, account: account, pipeline: pipeline, stage: won_stage, owner: teammate, team: team)
    hidden_deal = create(:crm_deal, account: account, pipeline: pipeline, stage: won_stage, owner: outsider)
    own_visit = terminal_visit(deal: own_deal, owner: viewer)
    team_visit = terminal_visit(deal: team_deal, owner: teammate, at: Time.utc(2026, 9, 11, 12))
    hidden_visit = terminal_visit(deal: hidden_deal, owner: outsider, at: Time.utc(2026, 9, 12, 12))
    enable_enforced_access!
    set_scope('view', 'own')
    set_scope('view_reports', 'all')

    get details_path, params: params, headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('payload', 'rows').pluck('stage_visit_id')).to eq([own_visit.id])
    expect(response.parsed_body.dig('meta', 'total_count')).to eq(1)

    set_scope('view', 'all')
    set_scope('view_reports', 'team')
    get details_path, params: params, headers: headers, as: :json
    expect(response.parsed_body.dig('payload', 'rows').pluck('stage_visit_id')).to contain_exactly(own_visit.id, team_visit.id)

    set_scope('view_reports', 'all')
    get details_path, params: params, headers: headers, as: :json
    expect(response.parsed_body.dig('payload', 'rows').pluck('stage_visit_id')).to contain_exactly(
      own_visit.id, team_visit.id, hidden_visit.id
    )

    set_scope('view_reports', 'none')
    get aggregate_path, params: params, headers: headers, as: :json
    expect(response).to have_http_status(:unauthorized)
  end

  it 'preserves authentication, feature, report permission, and validation boundaries' do
    get aggregate_path, params: params, as: :json
    expect(response).to have_http_status(:unauthorized)

    account.disable_features!('crm_deals')
    get aggregate_path, params: params, headers: headers, as: :json
    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body['code']).to eq('FEATURE_DISABLED')
    account.enable_features!('crm_deals')

    plain_agent = create(:user, account: account)
    get aggregate_path, params: params, headers: plain_agent.create_new_auth_token, as: :json
    expect(response).to have_http_status(:unauthorized)

    get aggregate_path, params: params.except(:as_of_date), headers: headers, as: :json
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body).to include('code' => 'INVALID_REPORT_QUERY', 'error' => 'as_of_date is required')
  end
end
