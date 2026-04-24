require 'rails_helper'

RSpec.describe Captain::Tools::UpdateCompanyTool, type: :model do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:tool) { described_class.new(assistant) }
  let(:company) { create(:company, account: account, name: 'OldCo', domain: 'old.co') }
  let(:contact) { create(:contact, account: account, company: company) }
  let(:conversation) { create(:conversation, account: account, contact: contact) }
  let(:tool_context) { Struct.new(:state).new({ conversation: { id: conversation.id }, contact: { id: contact.id } }) }

  it 'returns normalized update_company payload' do
    payload = JSON.parse(tool.perform(tool_context, name: 'NewCo', domain: 'new.co', description: 'Updated'))

    expect(payload).to include('action' => 'update_company')
    expect(payload['company']).to include('id' => company.id, 'name' => 'NewCo', 'domain' => 'new.co', 'description' => 'Updated')
  end
end
