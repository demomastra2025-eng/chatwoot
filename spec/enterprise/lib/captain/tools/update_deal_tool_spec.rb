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

    payload = JSON.parse(tool.perform(tool_context, title: 'New title'))

    expect(payload).to include('action' => 'update_deal')
    expect(payload['deal']).to include('id' => deal.id, 'title' => 'New title')
  end
end
