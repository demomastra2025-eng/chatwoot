require 'rails_helper'

RSpec.describe 'CRM Stage Duration Reports API', type: :request do
  let(:account) { create(:account, reporting_timezone: 'Asia/Almaty') }
  let(:viewer) { create(:user, :administrator, account: account) }
  let(:headers) { viewer.create_new_auth_token }
  let(:aggregate_path) { "/api/v1/accounts/#{account.id}/crm/reports/stage_durations" }
  let(:details_path) { "/api/v1/accounts/#{account.id}/crm/reports/stage_duration_details" }
  let(:report_params) { { from_date: '2026-09-01', to_date: '2026-09-30' } }
  let(:pipeline) { create(:crm_pipeline, account: account, name: 'Sales', code: 'sales') }
  let(:stage) { create(:crm_stage, account: account, pipeline: pipeline, name: 'Qualified', code: 'qualified') }

  before do
    account.enable_features!('crm_deals')
  end

  def create_duration(deal:, at: Time.utc(2026, 9, 15, 12), duration: 1.hour, **attributes)
    visit_stage = attributes.fetch(:visit_stage, stage)
    create(
      :crm_stage_visit,
      account: deal.account,
      deal: deal,
      pipeline: visit_stage.pipeline,
      stage: visit_stage,
      entered_at: at - duration,
      exited_at: at,
      estimated: attributes.fetch(:estimated, false),
      reliable_since: attributes.fetch(:reliable_since, at - duration)
    )
  end

  def get_aggregate(params = report_params)
    get aggregate_path, params: params, headers: headers, as: :json
  end

  def get_details(params = report_params)
    get details_path, params: params, headers: headers, as: :json
  end

  it 'returns matching aggregate and paginated drill-down without mutable deal fields' do
    deal = create(
      :crm_deal,
      account: account,
      pipeline: pipeline,
      stage: stage,
      title: 'Must not leak',
      amount_minor: 999_999,
      currency: 'KZT',
      archived_at: Time.utc(2026, 9, 20)
    )
    visit = create_duration(deal: deal, duration: 2.hours, estimated: true)

    get_aggregate
    expect(response).to have_http_status(:ok)
    aggregate = response.parsed_body

    get_details(report_params.merge(page: 1, per_page: 1))
    details = response.parsed_body

    expect(aggregate.dig('payload', 'rows').sum { |row| row['total_count'] }).to eq(1)
    expect(aggregate.dig('payload', 'rows', 0)).to include(
      'exact_count' => 0,
      'estimated_count' => 1,
      'median_duration_seconds' => 7200.0
    )
    expect(details.dig('meta', 'total_count')).to eq(1)
    expect(details.dig('payload', 'rows')).to contain_exactly(
      include(
        'stage_visit_id' => visit.id,
        'deal_id' => deal.id,
        'duration_seconds' => 7200,
        'reliability' => 'estimated'
      )
    )
    expect(details.to_json).not_to include('Must not leak', '999999')
    expect(aggregate.dig('meta', 'query_fingerprint')).to eq(details.dig('meta', 'query_fingerprint'))
  end

  it 'reports unknown top-level coverage consistently for mixed exact and pre-reliability facts' do
    exact_deal = create(:crm_deal, account: account, pipeline: pipeline, stage: stage)
    unknown_deal = create(:crm_deal, account: account, pipeline: pipeline, stage: stage)
    create_duration(deal: exact_deal, at: Time.utc(2026, 9, 10, 12), reliable_since: Time.utc(2026, 8, 1))
    create_duration(deal: unknown_deal, at: Time.utc(2026, 9, 15, 12), reliable_since: Time.utc(2026, 9, 16))

    get_aggregate
    expect(response.parsed_body.dig('meta', 'coverage')).to eq('unknown_before')

    get_details
    expect(response.parsed_body.dig('meta', 'coverage')).to eq('unknown_before')
  end

  it 'keeps report access on the existing administrator-only policy' do
    get_aggregate
    expect(response).to have_http_status(:ok)

    agent = create(:user, account: account, role: :agent)
    get aggregate_path, params: report_params, headers: agent.create_new_auth_token, as: :json
    expect(response).to have_http_status(:unauthorized)
  end

  it 'keeps drill-down facts inside the account and omits mutable deal details' do
    visible_deal = create(:crm_deal, account: account, pipeline: pipeline, stage: stage, title: 'Visible deal title')
    create_duration(deal: visible_deal)

    foreign_account = create(:account)
    foreign_pipeline = create(:crm_pipeline, account: foreign_account, name: 'Foreign pipeline')
    foreign_stage = create(:crm_stage, account: foreign_account, pipeline: foreign_pipeline, name: 'Foreign stage')
    foreign_deal = create(:crm_deal, account: foreign_account, pipeline: foreign_pipeline, stage: foreign_stage)
    create_duration(deal: foreign_deal, visit_stage: foreign_stage)

    get_aggregate
    body = response.parsed_body
    expect(response).to have_http_status(:ok)
    expect(body.dig('payload', 'rows').sum { |row| row['total_count'] }).to eq(1)
    expect(body.to_json).not_to include('Visible deal title', 'Foreign pipeline', 'Foreign stage')
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
