require 'rails_helper'

RSpec.describe Captain::Tools::CreateDealTool, type: :model do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:tool) { described_class.new(assistant) }

  before do
    account.enable_features!('crm_deals')
  end

  it 'returns normalized create_deal payload' do
    contact = create(:contact, account: account)
    conversation = create(:conversation, account: account, contact: contact)
    tool_context = Struct.new(:state).new({ conversation: { id: conversation.id }, contact: { id: contact.id } })

    payload = JSON.parse(tool.perform(tool_context, title: 'Enterprise renewal', amount: '200.00', currency: 'USD'))

    expect(payload).to include('action' => 'create_deal')
    expect(payload['deal']).to include(
      'title' => 'Enterprise renewal',
      'originating_conversation_id' => conversation.id,
      'amount' => '200'
    )
    expect(payload['deal']).not_to have_key('amount_minor')
    expect(payload.to_json).not_to include('20000')
  end
end
