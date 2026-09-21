require 'rails_helper'

RSpec.describe Captain::Tools::Agent::AccountToolAdapter, type: :model do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:tool) { described_class.new(assistant, tool_id: 'search_deals') }

  before do
    account.enable_features!('crm_deals')
    allow(Captain::ToolPolicy).to receive(:execution_allowed?).and_return(true)
    allow(tool).to receive(:audit_tool_execution)
  end

  it 'propagates customer-agent scope to an account-tool delegate' do
    conversation = create(:conversation, account: account)
    current_contact_deal = create(:crm_deal, account: account, title: 'Shared renewal')
    create(:crm_deal_contact, account: account, deal: current_contact_deal, contact: conversation.contact, primary: true)
    create(:crm_deal, account: account, title: 'Shared renewal')
    tool_context = Struct.new(:state, :context).new({ conversation: { id: conversation.id } }, {})

    payload = JSON.parse(tool.execute(tool_context, query: 'Shared renewal'))

    expect(tool.send(:delegate_class)).to eq(Captain::Tools::Account::SearchDealsService)
    expect(payload['filters']).to include('contact_id' => conversation.contact_id)
    expect(payload['deals'].map { |deal| deal['id'] }).to contain_exactly(current_contact_deal.id)
  end

  it 'keeps an update delegate inside the current contact scope' do
    conversation = create(:conversation, account: account)
    foreign_deal = create(:crm_deal, account: account, title: 'Foreign deal')
    update_tool = described_class.new(assistant, tool_id: 'update_deal')
    allow(update_tool).to receive(:audit_tool_execution)
    tool_context = Struct.new(:state, :context).new({ conversation: { id: conversation.id } }, {})

    result = update_tool.execute(tool_context, deal_id: foreign_deal.id, title: 'Leaked update')

    expect(result).to include('ERROR:', 'ActiveRecord::RecordNotFound')
    expect(foreign_deal.reload.title).to eq('Foreign deal')
  end
end
