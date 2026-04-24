require 'rails_helper'

RSpec.describe Captain::Tools::Copilot::SearchCompaniesService do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:service) { described_class.new(assistant, user: user) }

  let!(:company1) { create(:company, account: account, name: 'OneLink Health', domain: 'onelink.health') }
  let!(:company2) { create(:company, account: account, name: 'OneLink Dental', domain: 'onelink.dental') }

  describe '#execute' do
    it 'returns normalized companies with filters and total_count' do
      payload = JSON.parse(service.execute(name: 'Health', limit: 1))

      expect(payload['filters']).to include('name' => 'Health')
      expect(payload['total_count']).to eq(1)
      expect(payload['companies'].length).to eq(1)
      expect(payload['companies'].first).to include(
        'id' => company1.id,
        'name' => 'OneLink Health',
        'domain' => 'onelink.health'
      )
    end
  end
end
