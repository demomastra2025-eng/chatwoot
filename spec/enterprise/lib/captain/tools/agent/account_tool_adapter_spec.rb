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

  it 'denies a legacy deal search even when its delegate would filter to the current contact' do
    conversation = create(:conversation, account: account)
    current_contact_deal = create(:crm_deal, account: account, title: 'Shared renewal')
    create(:crm_deal_contact, account: account, deal: current_contact_deal, contact: conversation.contact, primary: true)
    create(:crm_deal, account: account, title: 'Shared renewal')
    tool_context = Struct.new(:state, :context).new({ conversation: { id: conversation.id } }, {})

    expect(tool).not_to receive(:invoke_delegate)
    expect { tool.execute(tool_context, query: 'Shared renewal') }
      .to raise_error(Captain::CustomerToolExecutionScope::Denied)
    expect(tool.send(:delegate_class)).to eq(Captain::Tools::Account::SearchDealsService)
    expect(current_contact_deal.reload.title).to eq('Shared renewal')
  end

  it 'denies a legacy deal update before its delegate sees a foreign deal' do
    conversation = create(:conversation, account: account)
    foreign_deal = create(:crm_deal, account: account, title: 'Foreign deal')
    update_tool = described_class.new(assistant, tool_id: 'update_deal')
    allow(update_tool).to receive(:audit_tool_execution)
    tool_context = Struct.new(:state, :context).new({ conversation: { id: conversation.id } }, {})

    expect(update_tool).not_to receive(:invoke_delegate)
    expect { update_tool.execute(tool_context, deal_id: foreign_deal.id, title: 'Leaked update') }
      .to raise_error(Captain::CustomerToolExecutionScope::Denied)

    expect(foreign_deal.reload.title).to eq('Foreign deal')
  end
end
