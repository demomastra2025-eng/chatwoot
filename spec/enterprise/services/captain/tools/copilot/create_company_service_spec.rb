require 'rails_helper'

RSpec.describe Captain::Tools::Copilot::CreateCompanyService do
  let(:account) { create(:account) }
  let(:user) { create(:user, :administrator, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:contact) { create(:contact, account: account, name: 'Aruzhan') }
  let(:conversation) { create(:conversation, account: account, contact: contact) }
  let(:service) { described_class.new(assistant, user: user, conversation: conversation) }

  it 'returns normalized company payload wrapper' do
    payload = JSON.parse(service.execute(name: 'OneLink', domain: 'onelink.kz', description: 'CRM'))

    expect(payload).to include('action' => 'create_company')
    expect(payload['company']).to include(
      'name' => 'OneLink',
      'domain' => 'onelink.kz',
      'description' => 'CRM'
    )
  end
end
