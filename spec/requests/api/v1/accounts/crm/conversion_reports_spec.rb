require 'rails_helper'

RSpec.describe 'CRM Conversion Reports API', type: :request do
  let(:account) { create(:account, settings: { 'workspace_timezone' => 'Asia/Almaty' }) }
  let(:viewer) { create(:user, :administrator, account: account) }
  let(:headers) { viewer.create_new_auth_token }
  let(:aggregate_path) { "/api/v1/accounts/#{account.id}/crm/reports/conversions" }
  let(:details_path) { "/api/v1/accounts/#{account.id}/crm/reports/conversion_details" }
  let(:report_params) { { from_date: '2026-09-01', to_date: '2026-09-30', as_of_date: '2026-10-31' } }
  let(:pipeline) { create(:crm_pipeline, account: account, name: 'Sales', code: 'sales') }
  let(:new_stage) { create(:crm_stage, account: account, pipeline: pipeline, name: 'New', code: 'new') }
  let(:lost_stage) { create(:crm_stage, account: account, pipeline: pipeline, name: 'Lost', code: 'lost', outcome: 'lost') }

  before do
    account.enable_features!('crm_deals')
  end

  def create_conversion(deal:, outcome_stage: lost_stage, at: Time.utc(2026, 9, 15, 12), reasons: ['Budget']) # rubocop:disable Metrics/MethodLength
    create(
      :crm_stage_visit,
      account: deal.account,
      deal: deal,
      pipeline: new_stage.pipeline,
      stage: new_stage,
      entered_at: at,
      exited_at: at + 1.day,
      reliable_since: at
    )
    terminal = create(
      :crm_stage_visit,
      account: deal.account,
      deal: deal,
      pipeline: outcome_stage.pipeline,
      stage: outcome_stage,
      entered_at: at + 1.day,
      reliable_since: at,
      correlation_id: SecureRandom.uuid
    )
    create(
      :crm_event,
      account: deal.account,
      eventable: deal,
      event_type: 'deal_stage_changed',
      correlation_id: terminal.correlation_id,
      after_data: { stage_id: terminal.stage_id, pipeline_id: terminal.pipeline_id, closing_reasons: reasons }
    )
    terminal
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

  it 'returns matching aggregate and paginated immutable drill-down with one query fingerprint' do # rubocop:disable RSpec/MultipleExpectations
    deal = create(
      :crm_deal,
      account: account,
      pipeline: pipeline,
      stage: lost_stage,
      title: 'Must not leak',
      amount_minor: 999_999,
      currency: 'KZT',
      archived_at: Time.utc(2026, 10, 20)
    )
    terminal = create_conversion(deal: deal)

    get aggregate_path, params: report_params, headers: headers, as: :json
    aggregate = response.parsed_body
    expect(response).to have_http_status(:ok)

    get details_path, params: report_params.merge(page: 1, per_page: 1), headers: headers, as: :json
    details = response.parsed_body

    expect(aggregate.dig('payload', 'rows').sum { |row| row['cohort_count'] }).to eq(1)
    expect(aggregate.dig('payload', 'rows', 0)).to include(
      'lost_count' => 1,
      'conversion_rate_percent' => 0.0,
      'loss_reasons' => [{ 'reason' => 'Budget', 'deal_count' => 1 }]
    )
    expect(details.dig('meta', 'total_count')).to eq(1)
    expect(details.dig('payload', 'rows')).to contain_exactly(
      include(
        'deal_id' => deal.id,
        'outcome' => 'lost',
        'closing_reasons' => ['Budget'],
        'terminal' => include('stage_visit_id' => terminal.id)
      )
    )
    expect(details.to_json).not_to include('Must not leak', '999999')
    expect(aggregate.dig('meta', 'query_fingerprint')).to eq(details.dig('meta', 'query_fingerprint'))
    expect(aggregate['meta']).to include(
      'source' => 'crm_stage_visits+crm_events',
      'definition_version' => 1,
      'cohort_definition' => 'first_stage_visit_entered_in_window'
    )
  end

  it 'applies Deal view and view_reports intersection before aggregate and drill-down' do
    other_user = create(:user, account: account)
    team = create(:team, account: account)
    create(:team_member, team: team, user: viewer)
    own_deal = create(:crm_deal, account: account, pipeline: pipeline, stage: lost_stage, owner: viewer)
    team_deal = create(:crm_deal, account: account, pipeline: pipeline, stage: lost_stage, owner: other_user, team: team)
    hidden_deal = create(:crm_deal, account: account, pipeline: pipeline, stage: lost_stage, owner: other_user)
    [own_deal, team_deal, hidden_deal].each { |deal| create_conversion(deal: deal) }
    enable_enforced_access!

    set_deal_scope('view', 'own')
    set_deal_scope('view_reports', 'all')
    get details_path, params: report_params, headers: headers, as: :json
    expect(response.parsed_body.dig('payload', 'rows').pluck('deal_id')).to contain_exactly(own_deal.id)

    set_deal_scope('view', 'all')
    set_deal_scope('view_reports', 'team')
    get aggregate_path, params: report_params, headers: headers, as: :json
    expect(response.parsed_body.dig('payload', 'rows').sum { |row| row['cohort_count'] }).to eq(2)

    set_deal_scope('view_reports', 'none')
    get details_path, params: report_params, headers: headers, as: :json
    expect(response).to have_http_status(:unauthorized)
  end

  it 'does not leak hidden or foreign facts and requires authentication' do
    visible = create(:crm_deal, account: account, pipeline: pipeline, stage: lost_stage, owner: viewer)
    create_conversion(deal: visible)
    hidden_pipeline = create(:crm_pipeline, account: account, name: 'Hidden pipeline', code: 'hidden')
    hidden_stage = create(:crm_stage, account: account, pipeline: hidden_pipeline, name: 'Hidden lost', code: 'hidden_lost', outcome: 'lost')
    hidden_owner = create(:user, account: account)
    hidden = create(:crm_deal, account: account, pipeline: hidden_pipeline, stage: hidden_stage, owner: hidden_owner)
    create_conversion(deal: hidden, outcome_stage: hidden_stage)

    foreign_account = create(:account)
    foreign_pipeline = create(:crm_pipeline, account: foreign_account, name: 'Foreign pipeline')
    foreign_stage = create(:crm_stage, account: foreign_account, pipeline: foreign_pipeline, name: 'Foreign lost', outcome: 'lost')
    foreign_deal = create(:crm_deal, account: foreign_account, pipeline: foreign_pipeline, stage: foreign_stage)
    create(
      :crm_stage_visit,
      account: foreign_account,
      deal: foreign_deal,
      pipeline: foreign_pipeline,
      stage: foreign_stage,
      entered_at: Time.utc(2026, 9, 15),
      reliable_since: Time.utc(2026, 9, 15)
    )

    enable_enforced_access!
    set_deal_scope('view', 'own')
    set_deal_scope('view_reports', 'all')
    get aggregate_path, params: report_params, headers: headers, as: :json

    body = response.parsed_body
    expect(body.dig('payload', 'rows').sum { |row| row['cohort_count'] }).to eq(1)
    expect(body.to_json).not_to include('Hidden pipeline', 'Hidden lost', 'Foreign pipeline', 'Foreign lost')

    get aggregate_path, params: report_params, as: :json
    expect(response).to have_http_status(:unauthorized)
  end

  it 'returns the CRM validation envelope for invalid cohort queries' do
    get aggregate_path, params: report_params.except(:as_of_date), headers: headers, as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body).to include(
      'code' => 'INVALID_REPORT_QUERY',
      'error' => 'as_of_date is required'
    )
  end
end
