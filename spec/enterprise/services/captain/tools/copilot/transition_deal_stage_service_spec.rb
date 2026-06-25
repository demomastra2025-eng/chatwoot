require 'rails_helper'

RSpec.describe Captain::Tools::Copilot::TransitionDealStageService do
  let(:account) { create(:account) }
  let(:user) { create(:user, :administrator, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:conversation) { create(:conversation, account: account) }
  let(:copilot_thread) { create(:captain_copilot_thread, account: account, user: user, assistant: assistant) }
  let(:service) { described_class.new(assistant, user: user, conversation: conversation, copilot_thread: copilot_thread) }

  before do
    account.enable_features!('crm_deals')
  end

  it 'returns normalized transitioned deal payload wrapper' do
    pipeline = create(:crm_pipeline, account: account)
    old_stage = create(:crm_stage, account: account, pipeline: pipeline, name: 'New', color: '#111111')
    new_stage = create(:crm_stage, account: account, pipeline: pipeline, name: 'Qualified', code: 'qualified', color: '#222222')
    deal = create(:crm_deal, account: account, pipeline: pipeline, stage: old_stage, originating_conversation_id: conversation.id)

    payload = JSON.parse(execute_confirmed(stage_code: 'Qualified'))

    expect(payload).to include('action' => 'transition_deal_stage', 'deal_id' => deal.id, 'pipeline_id' => pipeline.id, 'stage_id' => new_stage.id)
    expect(payload['deal']).to include(
      'id' => deal.id,
      'stage_id' => new_stage.id,
      'pipeline_id' => pipeline.id
    )
  end

  it 'resolves duplicate stage names within the current deal pipeline' do
    other_pipeline = create(:crm_pipeline, account: account, code: 'andalusiya', position: 1)
    target_pipeline = create(:crm_pipeline, account: account, code: 'andalusiya2', position: 2)
    other_stage = create(:crm_stage, account: account, pipeline: other_pipeline, name: 'В работе', code: 'work', position: 2, color: '#111111')
    current_stage = create(:crm_stage, account: account, pipeline: target_pipeline, name: 'Новый', code: 'new', position: 1, color: '#222222')
    target_stage = create(:crm_stage, account: account, pipeline: target_pipeline, name: 'В работе', code: 'work', position: 2, color: '#333333')
    deal = create(:crm_deal, account: account, pipeline: target_pipeline, stage: current_stage, originating_conversation_id: conversation.id)

    payload = JSON.parse(execute_confirmed(stage_name: 'В работе'))

    expect(payload['deal']).to include('id' => deal.id, 'stage_id' => target_stage.id, 'pipeline_id' => target_pipeline.id)
    expect(payload['deal']['stage_id']).not_to eq(other_stage.id)
  end

  it 'moves the current deal to the next stage by position in the same pipeline' do
    pipeline = create(:crm_pipeline, account: account)
    current_stage = create(:crm_stage, account: account, pipeline: pipeline, name: 'Новый', code: 'new', position: 1, color: '#111111')
    next_stage = create(:crm_stage, account: account, pipeline: pipeline, name: 'В работе', code: 'work', position: 2, color: '#222222')
    create(:crm_stage, account: account, pipeline: pipeline, name: 'Проиграно', code: 'lost', position: 3, outcome: 'lost', color: '#333333')
    deal = create(:crm_deal, account: account, pipeline: pipeline, stage: current_stage, originating_conversation_id: conversation.id)

    payload = JSON.parse(execute_confirmed(stage_action: 'next'))

    expect(payload['deal']).to include('id' => deal.id, 'stage_id' => next_stage.id, 'pipeline_id' => pipeline.id)
  end

  it 'passes closing reasons through the confirmed copilot tool call' do
    pipeline = create(:crm_pipeline, account: account)
    current_stage = create(:crm_stage, account: account, pipeline: pipeline, name: 'Новый', code: 'new', position: 1, color: '#111111')
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
    deal = create(:crm_deal, account: account, pipeline: pipeline, stage: current_stage, originating_conversation_id: conversation.id)

    payload = JSON.parse(execute_confirmed(stage_code: 'lost', closing_reasons: ['competitor']))

    expect(payload['deal']).to include('id' => deal.id, 'stage_id' => lost_stage.id, 'closing_reasons' => ['Competitor'])
    expect(deal.reload.closing_reasons).to eq(['Competitor'])
  end

  it 'rejects stage_action combined with explicit target selectors' do
    pipeline = create(:crm_pipeline, account: account)
    current_stage = create(:crm_stage, account: account, pipeline: pipeline, name: 'Новый', code: 'new', position: 1, color: '#111111')
    target_stage = create(:crm_stage, account: account, pipeline: pipeline, name: 'В работе', code: 'work', position: 2, color: '#222222')
    deal = create(:crm_deal, account: account, pipeline: pipeline, stage: current_stage, originating_conversation_id: conversation.id)

    result = execute_confirmed(stage_action: 'next', stage_id: target_stage.id)

    expect(result).to include('ERROR: ArgumentError: stage_action cannot be combined')
    expect(deal.reload.stage_id).to eq(current_stage.id)
  end

  def execute_confirmed(**arguments)
    first_result = service.execute(**arguments)
    first_payload = JSON.parse(first_result)
    return first_result unless first_payload.dig('data', 'confirmation_required')

    confirmation_token = copilot_thread.copilot_messages.assistant_thinking.last.message.dig('confirmation_gate', 'confirmation_token')

    create(
      :captain_copilot_message,
      account: account,
      copilot_thread: copilot_thread,
      message_type: 'user',
      message: { 'content' => "Подтверждаю #{confirmation_token}" }
    )

    service.execute(**arguments)
  end
end
