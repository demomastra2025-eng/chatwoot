require 'rails_helper'

RSpec.describe Captain::Tools::Account::SearchSchedulingServicesService do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:service) { described_class.new(assistant, user: user) }
  let!(:service1) { create(:scheduling_service, account: account, name: 'Consultation', category: 'Primary care', direction: 'North') }
  let!(:service2) { create(:scheduling_service, account: account, name: 'Dental cleaning', category: 'Dentistry', direction: 'South', active: false) }

  before do
    account.enable_features!('scheduling')
  end

  describe '#execute' do
    it 'returns normalized scheduling services with filters and total_count' do
      resource = create(:scheduling_resource, account: account)
      create(:scheduling_service_price, account: account, service: service1, resource: resource,
                                        price: 20_000, compensation_type: 'fixed', compensation_value: 7_000)
      payload = JSON.parse(service.execute(query: 'Consult', include_inactive: false, limit: 1))

      expect(payload['filters']).to include('query' => 'Consult', 'include_inactive' => false)
      expect(payload['total_count']).to eq(1)
      expect(payload['services'].length).to eq(1)
      expect(payload['services'].first).to include(
        'id' => service1.id,
        'name' => 'Consultation',
        'active' => true
      )
      expect(payload.dig('services', 0, 'prices', 0)).to include('price' => 20_000)
      expect(payload.dig('services', 0, 'prices', 0)).not_to include(
        'compensation_type', 'compensation_value', 'compensation_percent'
      )
    end
  end
end
