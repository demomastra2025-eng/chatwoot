require 'rails_helper'

RSpec.describe Captain::Tools::Copilot::UpdateCompanyService do
  let(:account) { create(:account) }
  let(:user) { create(:user, :administrator, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:company) { create(:company, account: account, name: 'OldCo', domain: 'old.co') }
  let(:contact) { create(:contact, account: account, company: company) }
  let(:conversation) { create(:conversation, account: account, contact: contact) }
  let(:service) { described_class.new(assistant, user: user, conversation: conversation) }

  it 'returns normalized updated company payload wrapper' do
    payload = JSON.parse(service.execute(name: 'NewCo', domain: 'new.co', description: 'Updated'))

    expect(payload).to include('action' => 'update_company', 'company_id' => company.id)
    expect(payload['company']).to include(
      'id' => company.id,
      'account_id' => account.id,
      'name' => 'NewCo',
      'domain' => 'new.co',
      'description' => 'Updated'
    )
  end
end
