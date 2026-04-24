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

    expect(payload).to include('action' => 'transition_deal_stage')
    expect(payload['deal']).to include('id' => deal.id, 'stage_id' => new_stage.id)
  end
end
