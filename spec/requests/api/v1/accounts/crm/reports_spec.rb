require 'rails_helper'

RSpec.describe 'CRM Deal Reports API', type: :request do
  let(:account) { create(:account) }
  let(:administrator) { create(:user, account: account, role: :administrator) }
  let(:headers) { administrator.create_new_auth_token }
  let(:path) { "/api/v1/accounts/#{account.id}/crm/reports/deals" }
  let(:legacy_path) { "/api/v1/accounts/#{account.id}/crm/reports/funnels" }
  let(:manager_effectiveness_path) { "/api/v1/accounts/#{account.id}/crm/reports/manager_effectiveness" }
  let(:manager_effectiveness_expected_row) do
    {
      'owner_name' => 'Manager One',
      'leads_count' => 3,
      'open_count' => 1,
      'bad_count' => 1,
      'won_count' => 1,
      'deal_amount_minor' => 600_000,
      'won_amount_minor' => 200_000,
      'call_attempts_count' => 2,
      'connected_calls_count' => 1,
      'long_calls_count' => 1,
      'appointments_count' => 1,
      'meeting_tasks_count' => 1,
      'meetings_count' => 1,
      'bad_rate' => 33.3,
      'lead_to_deal_conversion' => 33.3
    }
  end

  def create_deal_report_fixture_data
    pipeline = create(:crm_pipeline, account: account, name: 'Retail sales', code: 'retail_sales', default: true)
    new_stage = create(:crm_stage, account: account, pipeline: pipeline, name: 'New', code: 'new', outcome: 'open', position: 1)
    proposal_stage = create(:crm_stage, account: account, pipeline: pipeline, name: 'Proposal', code: 'proposal', outcome: 'open', position: 2)
    won_stage = create(:crm_stage, account: account, pipeline: pipeline, name: 'Won', code: 'won', outcome: 'won', position: 3)
    lost_stage = create(:crm_stage, account: account, pipeline: pipeline, name: 'Lost', code: 'lost', outcome: 'lost', position: 4)
    owner = create(:user, account: account, role: :agent, name: 'Sarah Sales')
    create_deal_report_records(
      pipeline: pipeline,
      stages: [new_stage, proposal_stage, won_stage, lost_stage],
      owner: owner
    )
    [new_stage, proposal_stage, owner]
  end

  def create_deal_report_records(pipeline:, stages:, owner:)
    new_stage, proposal_stage, won_stage, lost_stage = stages
    records = [
      { stage: new_stage, owner: owner, amount_minor: 100_000, win_probability: 20,
        expected_close_on: 3.days.from_now.to_date, custom_attributes: { 'source' => 'conversation' }, created_at: 1.day.ago },
      { stage: proposal_stage, owner: owner, amount_minor: 200_000, win_probability: 50,
        expected_close_on: 10.days.from_now.to_date, custom_attributes: { 'source' => 'ai' }, created_at: 1.day.ago },
      { stage: won_stage, owner: owner, amount_minor: 300_000, closed_at: 1.day.ago,
        custom_attributes: { 'source' => 'conversation' }, created_at: 2.days.ago },
      { stage: lost_stage, amount_minor: 400_000, closed_at: 1.day.ago,
        custom_attributes: { 'source' => 'manual' }, created_at: 2.days.ago }
    ]
    records.each { |attributes| create(:crm_deal, account: account, pipeline: pipeline, currency: 'KZT', **attributes) }
    create(:crm_deal, account: account, pipeline: pipeline, stage: new_stage, amount_minor: 999_000,
                      currency: 'KZT', archived_at: Time.current)
    create(:crm_deal, amount_minor: 888_000, currency: 'KZT')
  end

  def assert_deal_report_summary(summary)
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
  end

  def assert_deal_report_breakdown(payload, new_stage, proposal_stage, owner)
    assert_deal_report_stages(payload, new_stage, proposal_stage)
    assert_forecast_total(payload)
    assert_conversation_source_report(payload)
    assert_owner_report(payload, owner)
  end

  def assert_deal_report_stages(payload, new_stage, proposal_stage)
    rows = payload.fetch('stage_distribution')
    expect(rows.find { |stage| stage['stage_id'] == new_stage.id }).to include('deal_count' => 1, 'amount_minor' => 100_000)
    expect(rows.find { |stage| stage['stage_id'] == proposal_stage.id }).to include('deal_count' => 1, 'amount_minor' => 200_000)
  end

  def assert_forecast_total(payload)
    total = payload.fetch('forecast_by_period').sum { |period| period['amount_minor'] }
    expect(total).to eq(300_000)
  end

  def assert_conversation_source_report(payload)
    source = payload.fetch('source_performance').find { |item| item['source'] == 'conversation' }
    expect(source).to include('deal_count' => 2, 'won_count' => 1, 'win_rate' => 100.0)
  end

  def assert_owner_report(payload, owner)
    row = payload.fetch('owner_performance').find { |item| item['owner_id'] == owner.id }
    expect(row).to include('owner_name' => 'Sarah Sales', 'deal_count' => 3, 'won_count' => 1)
  end

  def create_manager_effectiveness_fixture
    pipeline = create(:crm_pipeline, account: account, name: 'Sales', code: 'sales', default: true)
    open_stage = create(:crm_stage, account: account, pipeline: pipeline, outcome: 'open', position: 1)
    won_stage = create(:crm_stage, account: account, pipeline: pipeline, outcome: 'won', position: 2)
    lost_stage = create(:crm_stage, account: account, pipeline: pipeline, outcome: 'lost', position: 3)
    owner = create(:user, account: account, role: :agent, name: 'Manager One')
    binding = create(:telephony_agent_binding, account: account, user: owner)
    conversation = create(:conversation, account: account)
    create_manager_effectiveness_deals(
      pipeline: pipeline,
      stages: [open_stage, won_stage, lost_stage],
      owner: owner,
      conversation: conversation
    )
    create_manager_effectiveness_activities(owner, binding)
    owner
  end

  def create_manager_effectiveness_deals(pipeline:, stages:, owner:, conversation:)
    open_stage, won_stage, lost_stage = stages
    records = [
      { stage: open_stage, owner: owner, originating_conversation: conversation, amount_minor: 100_000, created_at: 1.day.ago },
      { stage: won_stage, owner: owner, originating_conversation: conversation, amount_minor: 200_000, created_at: 1.day.ago },
      { stage: lost_stage, owner: owner, originating_conversation: conversation, amount_minor: 300_000, created_at: 1.day.ago },
      { stage: open_stage, owner: owner, amount_minor: 700_000, created_at: 1.day.ago },
      { stage: open_stage, owner: owner, originating_conversation: conversation, amount_minor: 900_000, created_at: 45.days.ago }
    ]
    records.each { |attributes| create(:crm_deal, account: account, pipeline: pipeline, currency: 'KZT', **attributes) }
    create(:crm_deal, amount_minor: 800_000, currency: 'KZT', created_at: 1.day.ago)
  end

  def create_manager_effectiveness_activities(owner, binding)
    create_manager_call_activities(binding)
    create_manager_appointment_activities(owner)
    create(:crm_task, account: account, assignee: owner, activity_type: 'meeting', due_at: 1.day.ago)
  end

  def create_manager_call_activities(binding)
    create(:telephony_call_session, account: account, agent_binding: binding, status: 'completed',
                                    started_at: 1.day.ago, answered_at: 1.day.ago, duration_seconds: 35)
    create(:telephony_call_session, account: account, agent_binding: binding, status: 'no_answer',
                                    started_at: 1.day.ago, duration_seconds: 0)
    create(:telephony_call_session, account: account, agent_binding: binding, direction: 'inbound',
                                    status: 'completed', started_at: 1.day.ago, duration_seconds: 80)
  end

  def create_manager_appointment_activities(owner)
    create(:scheduling_appointment, account: account, owner: owner, status: 'completed',
                                   starts_at: 1.day.ago, ends_at: 1.day.ago + 30.minutes)
  end

  def assert_manager_effectiveness_row(row)
    expect(row).to include(manager_effectiveness_expected_row)
  end

  before do
    account.enable_features!('crm_deals')
  end

  it 'returns account-scoped deal report aggregates' do
    travel_to Time.zone.local(2026, 1, 15, 12, 0, 0) do
      new_stage, proposal_stage, owner = create_deal_report_fixture_data
      get path, params: { since: 7.days.ago.to_i.to_s, until: 14.days.from_now.to_i.to_s, group_by: 'week' },
                headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      payload = response.parsed_body.fetch('payload')
      assert_deal_report_summary(payload.fetch('summary'))
      assert_deal_report_breakdown(payload, new_stage, proposal_stage, owner)
    end
  end

  it 'keeps the legacy funnels path as an alias' do
    get legacy_path, headers: headers, as: :json

    expect(response).to have_http_status(:ok)
  end

  it 'aggregates account deal data using the existing report policy' do
    pipeline = create(:crm_pipeline, account: account, default: true)
    stage = create(:crm_stage, account: account, pipeline: pipeline, outcome: 'open')
    other_agent = create(:user, account: account, role: :agent)
    own_conversation = create(:conversation, account: account)
    other_conversation = create(:conversation, account: account)
    create(
      :crm_deal,
      account: account,
      owner: administrator,
      pipeline: pipeline,
      stage: stage,
      originating_conversation: own_conversation,
      amount_minor: 100_000,
      currency: 'KZT'
    )
    create(
      :crm_deal,
      account: account,
      owner: other_agent,
      pipeline: pipeline,
      stage: stage,
      originating_conversation: other_conversation,
      amount_minor: 900_000,
      currency: 'KZT'
    )
    other_binding = create(:telephony_agent_binding, account: account, user: other_agent)
    create(
      :telephony_call_session,
      account: account,
      agent_binding: other_binding,
      direction: 'outbound',
      status: 'completed',
      started_at: 1.day.ago
    )
    get path, headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('payload', 'summary')).to include(
      'created_deals_count' => 2,
      'open_deals_count' => 2,
      'pipeline_amount_minor' => 1_000_000
    )

    get manager_effectiveness_path, headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('payload', 'totals', 'leads_count')).to eq(2)
    expect(response.parsed_body.dig('payload', 'rows').pluck('owner_id'))
      .to contain_exactly(administrator.id, other_agent.id)
  end

  it 'includes task metrics visible under the existing account report policy' do
    pipeline = create(:crm_pipeline, account: account, default: true)
    stage = create(:crm_stage, account: account, pipeline: pipeline, outcome: 'open')
    owner = create(:user, account: account, role: :agent)
    conversation = create(:conversation, account: account)
    create(
      :crm_deal,
      account: account,
      owner: owner,
      pipeline: pipeline,
      stage: stage,
      originating_conversation: conversation
    )
    create(:crm_task, account: account, assignee: owner, activity_type: 'meeting', due_at: 1.day.ago)
    get manager_effectiveness_path, headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    owner_row = response.parsed_body.dig('payload', 'rows').find { |row| row['owner_id'] == owner.id }
    expect(owner_row).to include('meeting_tasks_count' => 1)
  end

  it 'returns manager effectiveness metrics from native CRM, telephony, scheduling, and payment data' do
    travel_to Time.zone.local(2026, 1, 15, 12, 0, 0) do
      owner = create_manager_effectiveness_fixture
      get manager_effectiveness_path,
          params: { since: 7.days.ago.to_i.to_s, until: 1.day.from_now.to_i.to_s, call_duration_threshold_seconds: '25' },
          headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      payload = response.parsed_body.fetch('payload')
      row = payload.fetch('rows').find { |item| item['owner_id'] == owner.id }
      assert_manager_effectiveness_row(row)
      expect(payload.fetch('totals')).to include(
        'leads_count' => 3,
        'meetings_count' => 1,
        'payments_amount_minor' => 12_000,
        'lead_to_meeting_conversion' => 33.3
      )
      expect(response.parsed_body.dig('meta', 'call_duration_threshold_seconds')).to eq(25)
    end
  end

  it 'includes mixed-source metrics for an all-scope owner without a deal' do
    owner = create(:user, account: account, role: :agent)
    binding = create(:telephony_agent_binding, account: account, user: owner)
    create(
      :telephony_call_session,
      account: account,
      agent_binding: binding,
      direction: 'outbound',
      status: 'completed',
      started_at: 1.day.ago,
      duration_seconds: 30
    )

    get manager_effectiveness_path, headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('payload', 'rows').find { |row| row['owner_id'] == owner.id }).to include(
      'leads_count' => 0,
      'call_attempts_count' => 1,
      'connected_calls_count' => 1
    )
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
