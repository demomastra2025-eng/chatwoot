require 'rails_helper'

RSpec.describe Captain::Tools::ListDealCustomFieldsTool, type: :model do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:tool) { described_class.new(assistant) }
  let(:tool_context) { Struct.new(:state).new({ account_id: account.id }) }

  it 'returns the account-scoped deal field catalog as structured JSON' do
    catalog = instance_double(
      Captain::Tools::CrmCustomFieldCatalog,
      fields: [
        {
          key: 'customer_tier',
          label: 'Customer tier',
          type: 'select',
          required: false,
          options: [{ label: 'Gold', value: 'gold' }]
        }
      ]
    )
    allow(Captain::Tools::CrmCustomFieldCatalog).to receive(:new)
      .with(account: account, entity_kind: 'deal')
      .and_return(catalog)

    result = JSON.parse(tool.perform(tool_context))

    expect(result).to include(
      'action' => 'list_deal_custom_fields',
      'entity_kind' => 'deal',
      'returned_count' => 1
    )
    expect(result['fields']).to contain_exactly(
      include('key' => 'customer_tier', 'type' => 'select', 'required' => false)
    )
  end

  it 'returns a normalized failure instead of raising an exception' do
    allow(Captain::Tools::CrmCustomFieldCatalog).to receive(:new).and_raise(StandardError, 'database details')

    expect(tool.perform(tool_context)).to eq('ERROR: StandardError: database details')
  end
end
