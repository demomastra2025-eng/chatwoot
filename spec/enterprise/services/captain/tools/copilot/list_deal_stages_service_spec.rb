require 'rails_helper'

RSpec.describe Captain::Tools::Copilot::ListDealStagesService do
  let(:account) { create(:account) }
  let(:user) { create(:user, :administrator, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:conversation) { create(:conversation, account: account) }
  let(:service) { described_class.new(assistant, user: user, conversation: conversation) }

  before do
    account.enable_features!('crm_deals')
  end

  it 'returns stages for the requested pipeline and next/previous around the current deal' do
    other_pipeline = create(:crm_pipeline, account: account, name: 'Andalusiya', code: 'andalusiya', position: 1, default: true)
    pipeline = create(:crm_pipeline, account: account, name: 'Andalusiya2', code: 'andalusiya2', position: 2)
    create(:crm_stage, account: account, pipeline: other_pipeline, name: 'В работе', code: 'work', position: 2, color: '#111111')

    first_stage = create(:crm_stage, account: account, pipeline: pipeline, name: 'Новый', code: 'new', position: 1, color: '#222222')
    current_stage = create(:crm_stage, account: account, pipeline: pipeline, name: 'В работе', code: 'work', position: 2, color: '#333333')
    next_stage = create(:crm_stage, account: account, pipeline: pipeline, name: 'Принимает решение', code: 'decision', position: 3, color: '#444444')
    inactive_stage = create(:crm_stage, account: account, pipeline: pipeline, name: 'Inactive', code: 'inactive', active: false, position: 4,
                                        color: '#555555')
    deal = create(:crm_deal, account: account, pipeline: pipeline, stage: current_stage, originating_conversation_id: conversation.id)

    payload = JSON.parse(service.execute(current_deal: true))

    expect(payload['action']).to eq('list_deal_stages')
    expect(payload['pipeline']).to include('id' => pipeline.id, 'code' => 'andalusiya2')
    expect(payload['pipeline']).not_to have_key('deal_count')
    expect(payload['current_deal']).to include('id' => deal.id, 'stage_id' => current_stage.id)
    expect(payload['stages'].map { |stage| stage['id'] }).to eq([first_stage.id, current_stage.id, next_stage.id])
    expect(payload['stages']).not_to include(include('id' => inactive_stage.id))
    expect(payload['stages'].first).to include('default' => true)
    expect(payload['stages'].first).not_to have_key('deal_count')
    expect(payload['stages'].second).to include('default' => false)
    expect(payload['stages'].second).not_to have_key('deal_count')
    expect(payload['previous_stage']).to include('id' => first_stage.id, 'position' => 1)
    expect(payload['next_stage']).to include('id' => next_stage.id, 'position' => 3)
  end

  it 'filters by pipeline_code without mixing duplicate stage names from another pipeline' do
    pipeline_a = create(:crm_pipeline, account: account, code: 'a')
    pipeline_b = create(:crm_pipeline, account: account, code: 'b')
    create(:crm_stage, account: account, pipeline: pipeline_a, name: 'Новый', code: 'new', position: 1, color: '#111111')
    stage_b = create(:crm_stage, account: account, pipeline: pipeline_b, name: 'Новый', code: 'new', position: 1, color: '#222222')

    payload = JSON.parse(service.execute(pipeline_code: 'B'))

    expect(payload['pipeline']).to include('id' => pipeline_b.id, 'code' => 'b')
    expect(payload['stages'].map { |stage| stage['id'] }).to eq([stage_b.id])
  end

  it 'resolves a user-provided pipeline name without requiring a numeric ID' do
    pipeline = create(:crm_pipeline, account: account, name: 'Продажи', code: 'sales')
    stage = create(:crm_stage, account: account, pipeline: pipeline, name: 'Новый', code: 'new', position: 1, color: '#111111')

    payload = JSON.parse(service.execute(pipeline_name: 'продажи'))

    expect(payload['pipeline']).to include('id' => pipeline.id, 'name' => 'Продажи')
    expect(payload['stages'].map { |item| item['id'] }).to eq([stage.id])
  end

  it 'prioritizes an explicit pipeline selector over an unrelated guessed deal ID' do
    pipeline = create(:crm_pipeline, account: account, name: 'Продажи', code: 'sales')
    stage = create(:crm_stage, account: account, pipeline: pipeline, name: 'Новый', code: 'new', position: 1, color: '#111111')

    payload = JSON.parse(service.execute(pipeline_name: 'Продажи', deal_id: 1))

    expect(payload['pipeline']).to include('id' => pipeline.id)
    expect(payload['stages'].map { |item| item['id'] }).to eq([stage.id])
    expect(payload['filters']).not_to have_key('deal_id')
    expect(payload['ignored_filters']).to eq('deal_id' => 1)
  end

  it 'prioritizes a user-provided pipeline name over conflicting code and numeric ID selectors' do
    requested_pipeline = create(:crm_pipeline, account: account, name: 'Продажи', code: 'sales')
    requested_stage = create(:crm_stage, account: account, pipeline: requested_pipeline, code: 'new', position: 1, color: '#111111')
    conflicting_pipeline = create(:crm_pipeline, account: account, name: 'Другая', code: 'other')

    payload = JSON.parse(
      service.execute(pipeline_name: 'Продажи', pipeline_code: conflicting_pipeline.code, pipeline_id: conflicting_pipeline.id)
    )

    expect(payload['pipeline']).to include('id' => requested_pipeline.id)
    expect(payload['stages'].map { |item| item['id'] }).to eq([requested_stage.id])
    expect(payload['filters']).to include('pipeline_name' => 'Продажи')
    expect(payload['filters']).not_to include('pipeline_code', 'pipeline_id')
    expect(payload['ignored_filters']).to include('pipeline_code' => 'other', 'pipeline_id' => conflicting_pipeline.id)
  end

  it 'exposes configured transition and closing reasons for stage selection' do
    pipeline = create(:crm_pipeline, account: account, code: 'reasons')
    open_stage = create(
      :crm_stage,
      account: account,
      pipeline: pipeline,
      name: 'В работе',
      code: 'work',
      position: 1,
      transition_reason_options: ['Needs docs', 'Waiting payment'],
      transition_reason_required: true,
      color: '#111111'
    )
    lost_stage = create(
      :crm_stage,
      account: account,
      pipeline: pipeline,
      name: 'Проиграно',
      code: 'lost',
      position: 2,
      outcome: 'lost',
      closing_reason_options: ['Too expensive', 'Competitor'],
      closing_reason_required: true,
      color: '#222222'
    )

    payload = JSON.parse(service.execute(pipeline_code: 'Reasons'))

    expect(payload['stages']).to include(
      include(
        'id' => open_stage.id,
        'transition_reason_options' => ['Needs docs', 'Waiting payment'],
        'transition_reason_required' => true
      ),
      include(
        'id' => lost_stage.id,
        'closing_reason_options' => ['Too expensive', 'Competitor'],
        'closing_reason_required' => false
      )
    )
  end
end
