require 'rails_helper'

RSpec.describe Captain::Tools::Copilot::GetCompanyService do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:service) { described_class.new(assistant, user: user) }
  let(:company) { create(:company, account: account, name: 'OneLink', domain: 'onelink.kz', description: 'CRM') }

  it 'returns normalized company payload' do
    payload = JSON.parse(service.execute(company_id: company.id))

    expect(payload['company']).to include(
      'id' => company.id,
      'account_id' => account.id,
      'name' => 'OneLink',
      'domain' => 'onelink.kz',
      'description' => 'CRM'
    )
  end
end
