require 'rails_helper'

RSpec.describe Captain::Tools::CreateCompanyTool, type: :model do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:tool) { described_class.new(assistant) }
  let(:contact) { create(:contact, account: account, name: 'Aruzhan') }
  let(:conversation) { create(:conversation, account: account, contact: contact) }
  let(:tool_context) { Struct.new(:state).new({ conversation: { id: conversation.id }, contact: { id: contact.id } }) }

  it 'returns normalized create_company payload' do
    payload = JSON.parse(tool.perform(tool_context, name: 'OneLink', domain: 'onelink.kz', description: 'CRM'))

    expect(payload).to include('action' => 'create_company', 'company_id' => payload.dig('company', 'id'))
    expect(payload['company']).to include(
      'account_id' => account.id,
      'name' => 'OneLink',
      'domain' => 'onelink.kz',
      'description' => 'CRM',
      'contacts_count' => 1,
      'additional_attributes' => {},
      'custom_attributes' => {}
    )
  end
end
