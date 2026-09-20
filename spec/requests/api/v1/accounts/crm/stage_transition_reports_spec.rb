require 'rails_helper'

RSpec.describe 'CRM Stage Transition Reports API', type: :request do
  let(:account) { create(:account, settings: { 'workspace_timezone' => 'Asia/Almaty' }) }
  let(:viewer) { create(:user, :administrator, account: account) }
  let(:headers) { viewer.create_new_auth_token }
  let(:aggregate_path) { "/api/v1/accounts/#{account.id}/crm/reports/stage_transitions" }
  let(:details_path) { "/api/v1/accounts/#{account.id}/crm/reports/stage_transition_details" }
  let(:report_params) { { from_date: '2026-09-01', to_date: '2026-09-30' } }
  let(:pipeline) { create(:crm_pipeline, account: account, name: 'Sales', code: 'sales') }
  let(:first_stage) { create(:crm_stage, account: account, pipeline: pipeline, name: 'New', code: 'new') }
  let(:second_stage) { create(:crm_stage, account: account, pipeline: pipeline, name: 'Won', code: 'won', outcome: 'won') }

  before do
    account.enable_features!('crm_deals')
  end

  def create_transition(deal:, from_stage: first_stage, to_stage: second_stage, at: Time.utc(2026, 9, 15, 12))
    create(
      :crm_stage_visit,
      account: deal.account,
      deal: deal,
      pipeline: from_stage.pipeline,
      stage: from_stage,
      entered_at: at - 1.hour,
      exited_at: at
    )
    create(
      :crm_stage_visit,
      account: deal.account,
      deal: deal,
      pipeline: to_stage.pipeline,
      stage: to_stage,
      entered_at: at
    )
  end

  def get_aggregate(params = report_params)
    get aggregate_path, params: params, headers: headers, as: :json
  end

  def get_details(params = report_params)
    get details_path, params: params, headers: headers, as: :json
  end

  def enable_enforced_access!
    AccessControl::LegacyRoleAssigner.call(account: account, apply: true)
    AccessControl::ModeTransition.call(account: account, to: :shadow)
    AccessControl::ModeTransition.call(account: account, to: :enforced)
  end

  def set_deal_scope(capability, scope)
    viewer.account_users.find_by!(account: account).access_role.grants
          .find_by!(resource: 'deals', capability: capability)
          .update!(access_scope: scope)
  end

  it 'returns matching aggregate and paginated drill-down without mutable deal fields' do
    deal = create(
      :crm_deal,
      account: account,
      pipeline: pipeline,
      stage: second_stage,
      title: 'Must not leak',
      amount_minor: 999_999,
      currency: 'KZT',
      archived_at: Time.utc(2026, 9, 20)
    )
    destination = create_transition(deal: deal)

    get_aggregate
    expect(response).to have_http_status(:ok)
    aggregate = response.parsed_body

    get_details(report_params.merge(page: 1, per_page: 1))
    expect(response).to have_http_status(:ok)
    details = response.parsed_body

    expect(aggregate.dig('payload', 'rows').sum { |row| row['total_count'] }).to eq(1)
    expect(details.dig('meta', 'total_count')).to eq(1)
    expect(details.dig('payload', 'rows')).to contain_exactly(
      include(
        'transition_visit_id' => destination.id,
        'deal_id' => deal.id,
        'reliability' => 'exact',
        'coverage' => 'exact'
      )
    )
    expect(details.to_json).not_to include('Must not leak', '999999')
    expect(aggregate.dig('meta', 'query_fingerprint')).to eq(details.dig('meta', 'query_fingerprint'))
  end

  it 'applies the view and view_reports intersection for own, team, all, and none scopes' do
    other_user = create(:user, account: account)
    team = create(:team, account: account)
    create(:team_member, team: team, user: viewer)
    own_deal = create(:crm_deal, account: account, pipeline: pipeline, stage: second_stage, owner: viewer)
    team_deal = create(:crm_deal, account: account, pipeline: pipeline, stage: second_stage, owner: other_user, team: team)
    hidden_deal = create(:crm_deal, account: account, pipeline: pipeline, stage: second_stage, owner: other_user)
    [own_deal, team_deal, hidden_deal].each { |deal| create_transition(deal: deal) }
    enable_enforced_access!

    set_deal_scope('view', 'own')
    set_deal_scope('view_reports', 'all')
    get_details
    expect(response.parsed_body.dig('payload', 'rows').pluck('deal_id')).to contain_exactly(own_deal.id)

    set_deal_scope('view', 'all')
    set_deal_scope('view_reports', 'team')
    get_details
    expect(response.parsed_body.dig('payload', 'rows').pluck('deal_id')).to contain_exactly(own_deal.id, team_deal.id)

    set_deal_scope('view', 'none')
    get_details
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('meta', 'total_count')).to eq(0)

    set_deal_scope('view', 'all')
    set_deal_scope('view_reports', 'none')
    get_details
    expect(response).to have_http_status(:unauthorized)
  end

  it 'does not leak hidden or foreign deal facts or their snapshot names' do
    visible_deal = create(:crm_deal, account: account, pipeline: pipeline, stage: second_stage, owner: viewer)
    create_transition(deal: visible_deal)

    hidden_pipeline = create(:crm_pipeline, account: account, name: 'Hidden pipeline', code: 'hidden')
    hidden_from = create(:crm_stage, account: account, pipeline: hidden_pipeline, name: 'Hidden from', code: 'hidden_from')
    hidden_to = create(:crm_stage, account: account, pipeline: hidden_pipeline, name: 'Hidden to', code: 'hidden_to')
    hidden_owner = create(:user, account: account)
    hidden_deal = create(:crm_deal, account: account, pipeline: hidden_pipeline, stage: hidden_to, owner: hidden_owner)
    create_transition(deal: hidden_deal, from_stage: hidden_from, to_stage: hidden_to)

    foreign_account = create(:account)
    foreign_pipeline = create(:crm_pipeline, account: foreign_account, name: 'Foreign pipeline')
    foreign_from = create(:crm_stage, account: foreign_account, pipeline: foreign_pipeline, name: 'Foreign from')
    foreign_to = create(:crm_stage, account: foreign_account, pipeline: foreign_pipeline, name: 'Foreign to')
    foreign_deal = create(:crm_deal, account: foreign_account, pipeline: foreign_pipeline, stage: foreign_to)
    create_transition(deal: foreign_deal, from_stage: foreign_from, to_stage: foreign_to)

    enable_enforced_access!
    set_deal_scope('view', 'own')
    set_deal_scope('view_reports', 'all')
    get_aggregate

    body = response.parsed_body
    expect(response).to have_http_status(:ok)
    expect(body.dig('payload', 'rows').sum { |row| row['total_count'] }).to eq(1)
    expect(body.to_json).not_to include('Hidden pipeline', 'Hidden from', 'Hidden to', 'Foreign pipeline')
  end

  it 'returns the CRM validation error envelope for invalid report queries' do
    get_aggregate(from_date: '2026-09-31', to_date: '2026-10-01')

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body).to include(
      'code' => 'INVALID_REPORT_QUERY',
      'error' => 'from_date must be a valid date'
    )
  end
end
