require 'rails_helper'

RSpec.describe Captain::Tools::TransitionDealStageTool, type: :model do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:tool) { described_class.new(assistant) }

  before do
    account.enable_features!('crm_deals')
  end

  it 'returns normalized transition_deal_stage payload' do
    pipeline = create(:crm_pipeline, account: account)
    old_stage = create(:crm_stage, account: account, pipeline: pipeline, color: '#111111')
    new_stage = create(:crm_stage, account: account, pipeline: pipeline, code: 'qualified', color: '#222222')
    conversation = create(:conversation, account: account)
    deal = create(:crm_deal, account: account, pipeline: pipeline, stage: old_stage, originating_conversation_id: conversation.id)
    tool_context = Struct.new(:state).new({ conversation: { id: conversation.id }, deal: { id: deal.id } })

    payload = JSON.parse(tool.perform(tool_context, stage_code: 'qualified'))

    expect(payload).to include('action' => 'transition_deal_stage', 'deal_id' => deal.id, 'pipeline_id' => pipeline.id, 'stage_id' => new_stage.id)
    expect(payload['deal']).to include('id' => deal.id, 'stage_id' => new_stage.id)
    expect(payload['previous_stage']).to include('id' => old_stage.id)
    expect(payload['current_stage']).to include('id' => new_stage.id)
  end

  it 'supports relative next stage transitions' do
    pipeline = create(:crm_pipeline, account: account)
    current_stage = create(:crm_stage, account: account, pipeline: pipeline, code: 'new', position: 1, color: '#111111')
    next_stage = create(:crm_stage, account: account, pipeline: pipeline, code: 'work', position: 2, color: '#222222')
    conversation = create(:conversation, account: account)
    deal = create(:crm_deal, account: account, pipeline: pipeline, stage: current_stage, originating_conversation_id: conversation.id)
    tool_context = Struct.new(:state).new({ conversation: { id: conversation.id }, deal: { id: deal.id } })

    payload = JSON.parse(tool.perform(tool_context, stage_action: 'next'))

    expect(payload).to include('deal_id' => deal.id, 'pipeline_id' => pipeline.id, 'stage_id' => next_stage.id)
    expect(payload['deal']).to include('id' => deal.id, 'stage_id' => next_stage.id)
  end

  it 'passes closing reasons when transitioning to terminal stages' do
    pipeline = create(:crm_pipeline, account: account)
    current_stage = create(:crm_stage, account: account, pipeline: pipeline, code: 'new', position: 1, color: '#111111')
    lost_stage = create(
      :crm_stage,
      account: account,
      pipeline: pipeline,
      code: 'lost',
      outcome: 'lost',
      closing_reason_options: ['Too expensive', 'Competitor'],
      closing_reason_required: true,
      color: '#222222'
    )
    conversation = create(:conversation, account: account)
    deal = create(:crm_deal, account: account, pipeline: pipeline, stage: current_stage, originating_conversation_id: conversation.id)
    tool_context = Struct.new(:state).new({ conversation: { id: conversation.id }, deal: { id: deal.id } })

    payload = JSON.parse(tool.perform(tool_context, stage_code: 'lost', closing_reasons: ['competitor']))

    expect(payload['deal']).to include('id' => deal.id, 'stage_id' => lost_stage.id, 'closing_reasons' => ['Competitor'])
    expect(deal.reload.closing_reasons).to eq(['Competitor'])
  end

  it 'passes transition reason when transitioning to configured open stages' do
    pipeline = create(:crm_pipeline, account: account)
    current_stage = create(:crm_stage, account: account, pipeline: pipeline, code: 'new', position: 1, color: '#111111')
    target_stage = create(
      :crm_stage,
      account: account,
      pipeline: pipeline,
      code: 'work',
      position: 2,
      transition_reason_options: ['Needs docs', 'Waiting payment'],
      transition_reason_required: true,
      color: '#222222'
    )
    conversation = create(:conversation, account: account)
    deal = create(:crm_deal, account: account, pipeline: pipeline, stage: current_stage, originating_conversation_id: conversation.id)
    tool_context = Struct.new(:state).new({ conversation: { id: conversation.id }, deal: { id: deal.id } })

    payload = JSON.parse(tool.perform(tool_context, stage_code: 'work', transition_reason: 'waiting payment'))
    event = deal.reload.events.where(event_type: 'deal_stage_changed').last

    expect(payload['deal']).to include('id' => deal.id, 'stage_id' => target_stage.id)
    expect(event.meta['transition_reason']).to eq('Waiting payment')
  end

  it 'returns a validation error instead of looking up zero ID placeholders' do
    pipeline = create(:crm_pipeline, account: account)
    current_stage = create(:crm_stage, account: account, pipeline: pipeline, code: 'new', position: 1, color: '#111111')
    conversation = create(:conversation, account: account)
    deal = create(:crm_deal, account: account, pipeline: pipeline, stage: current_stage, originating_conversation_id: conversation.id)
    tool_context = Struct.new(:state).new({ conversation: { id: conversation.id }, deal: { id: deal.id } })

    result = tool.perform(tool_context, stage_id: 0, pipeline_id: '0')

    expect(result).to include(
      'ERROR: ArgumentError: One of stage_id, stage_name, stage_code, pipeline_id, pipeline_code, or stage_action is required'
    )
    expect(result).not_to include('ActiveRecord::RecordNotFound')
    expect(deal.reload.stage_id).to eq(current_stage.id)
  end
end
