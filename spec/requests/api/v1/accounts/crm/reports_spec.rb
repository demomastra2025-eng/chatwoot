require 'rails_helper'

RSpec.describe 'CRM Deal Reports API', type: :request do
  let(:account) { create(:account) }
  let(:administrator) { create(:user, account: account, role: :administrator) }
  let(:headers) { administrator.create_new_auth_token }
  let(:path) { "/api/v1/accounts/#{account.id}/crm/reports/deals" }
  let(:legacy_path) { "/api/v1/accounts/#{account.id}/crm/reports/funnels" }

  before do
    account.enable_features!('crm_deals')
  end

  it 'returns account-scoped deal report aggregates' do
    travel_to Time.zone.local(2026, 1, 15, 12, 0, 0) do
      pipeline = create(:crm_pipeline, account: account, name: 'Retail sales', code: 'retail_sales', default: true)
      new_stage = create(:crm_stage, account: account, pipeline: pipeline, name: 'New', code: 'new', color: '#2563EB', outcome: 'open', position: 1)
      proposal_stage = create(:crm_stage, account: account, pipeline: pipeline, name: 'Proposal', code: 'proposal', color: '#F97316',
                                          outcome: 'open', position: 2)
      won_stage = create(:crm_stage, account: account, pipeline: pipeline, name: 'Won', code: 'won', color: '#16A34A', outcome: 'won', position: 3)
      lost_stage = create(:crm_stage, account: account, pipeline: pipeline, name: 'Lost', code: 'lost', color: '#DC2626', outcome: 'lost',
                                      position: 4)
      owner = create(:user, account: account, role: :agent, name: 'Sarah Sales')

      create(
        :crm_deal,
        account: account,
        pipeline: pipeline,
        stage: new_stage,
        owner: owner,
        amount_minor: 100_000,
        currency: 'KZT',
        win_probability: 20,
        expected_close_on: 3.days.from_now.to_date,
        custom_attributes: { 'source' => 'conversation' },
        created_at: 1.day.ago
      )
      create(
        :crm_deal,
        account: account,
        pipeline: pipeline,
        stage: proposal_stage,
        owner: owner,
        amount_minor: 200_000,
        currency: 'KZT',
        win_probability: 50,
        expected_close_on: 10.days.from_now.to_date,
        custom_attributes: { 'source' => 'ai' },
        created_at: 1.day.ago
      )
      create(
        :crm_deal,
        account: account,
        pipeline: pipeline,
        stage: won_stage,
        owner: owner,
        amount_minor: 300_000,
        currency: 'KZT',
        closed_at: 1.day.ago,
        custom_attributes: { 'source' => 'conversation' },
        created_at: 2.days.ago
      )
      create(
        :crm_deal,
        account: account,
        pipeline: pipeline,
        stage: lost_stage,
        amount_minor: 400_000,
        currency: 'KZT',
        closed_at: 1.day.ago,
        custom_attributes: { 'source' => 'manual' },
        created_at: 2.days.ago
      )
      create(:crm_deal, account: account, pipeline: pipeline, stage: new_stage, amount_minor: 999_000, currency: 'KZT', archived_at: Time.current)
      create(:crm_deal, amount_minor: 888_000, currency: 'KZT')

      get path,
          params: {
            since: 7.days.ago.to_i.to_s,
            until: 14.days.from_now.to_i.to_s,
            group_by: 'week'
          },
          headers: headers,
          as: :json

      expect(response).to have_http_status(:ok)

      payload = response.parsed_body.fetch('payload')
      summary = payload.fetch('summary')
      new_stage_report = payload.fetch('stage_distribution').find { |stage| stage['stage_id'] == new_stage.id }
      proposal_stage_report = payload.fetch('stage_distribution').find { |stage| stage['stage_id'] == proposal_stage.id }
      conversation_source = payload.fetch('source_performance').find { |source| source['source'] == 'conversation' }
      owner_report = payload.fetch('owner_performance').find { |owner_payload| owner_payload['owner_id'] == owner.id }

      expect(summary).to include(
        'created_deals_count' => 4,
        'open_deals_count' => 2,
        'pipeline_amount_minor' => 300_000,
        'weighted_pipeline_amount_minor' => 120_000,
        'won_deals_count' => 1,
        'won_amount_minor' => 300_000,
        'lost_deals_count' => 1,
        'lost_amount_minor' => 400_000,
        'win_rate' => 50.0,
        'currency' => 'KZT'
      )
      expect(new_stage_report).to include('deal_count' => 1, 'amount_minor' => 100_000)
      expect(proposal_stage_report).to include('deal_count' => 1, 'amount_minor' => 200_000)
      expect(payload.fetch('forecast_by_period').sum { |period| period['amount_minor'] }).to eq(300_000)
      expect(conversation_source).to include('deal_count' => 2, 'won_count' => 1, 'win_rate' => 100.0)
      expect(owner_report).to include('owner_name' => 'Sarah Sales', 'deal_count' => 3, 'won_count' => 1)
    end
  end

  it 'keeps the legacy funnels path as an alias' do
    get legacy_path, headers: headers, as: :json

    expect(response).to have_http_status(:ok)
  end

  it 'returns unauthorized without auth' do
    get path, as: :json

    expect(response).to have_http_status(:unauthorized)
  end

  it 'returns forbidden when crm_deals is disabled' do
    account.disable_features!('crm_deals')

    get path, headers: headers, as: :json

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body['code']).to eq('FEATURE_DISABLED')
  end
end
