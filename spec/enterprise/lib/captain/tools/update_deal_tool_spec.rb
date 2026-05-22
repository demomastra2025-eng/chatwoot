require 'rails_helper'

RSpec.describe Captain::Tools::UpdateDealTool, type: :model do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:tool) { described_class.new(assistant) }

  before do
    account.enable_features!('crm_deals')
  end

  it 'returns normalized update_deal payload' do
    contact = create(:contact, account: account)
    conversation = create(:conversation, account: account, contact: contact)
    pipeline = create(:crm_pipeline, account: account)
    stage = create(:crm_stage, account: account, pipeline: pipeline, color: '#111111')
    deal = create(:crm_deal, account: account, title: 'Old title', pipeline: pipeline, stage: stage, originating_conversation_id: conversation.id)
    tool_context = Struct.new(:state).new({ conversation: { id: conversation.id }, deal: { id: deal.id }, contact: { id: contact.id } })

    payload = JSON.parse(tool.perform(tool_context, title: 'New title', amount: '200.00', currency: 'USD'))

    expect(payload).to include('action' => 'update_deal', 'deal_id' => deal.id)
    expect(payload['deal']).to include('id' => deal.id, 'title' => 'New title', 'amount' => '200')
    expect(payload['deal']).not_to have_key('amount_minor')
    expect(payload.to_json).not_to include('20000')
  end

  it 'updates and moves the deal to a selected pipeline stage' do
    contact = create(:contact, account: account)
    conversation = create(:conversation, account: account, contact: contact)
    deal = create(:crm_deal, account: account, originating_conversation_id: conversation.id)
    target_pipeline = create(:crm_pipeline, account: account, code: 'expansion')
    target_stage = create(:crm_stage, account: account, pipeline: target_pipeline, code: 'work', position: 1, color: '#111111')
    tool_context = Struct.new(:state).new({ conversation: { id: conversation.id }, deal: { id: deal.id }, contact: { id: contact.id } })

    payload = JSON.parse(tool.perform(tool_context, title: 'Moved deal', pipeline_code: 'expansion', stage_code: 'work'))

    expect(payload).to include('deal_id' => deal.id, 'pipeline_id' => target_pipeline.id, 'stage_id' => target_stage.id)
    expect(payload['deal']).to include('id' => deal.id, 'title' => 'Moved deal', 'pipeline_id' => target_pipeline.id, 'stage_id' => target_stage.id)
  end
end
