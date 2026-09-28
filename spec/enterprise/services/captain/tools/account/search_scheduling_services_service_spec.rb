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

    it 'matches Russian morphology and configured aliases without requiring an exact substring' do
      service1.update!(
        name: 'МРТ шейного отдела позвоночника',
        custom_attributes: { 'aliases' => ['магнитно резонансная томография шеи'] }
      )

      payload = JSON.parse(service.execute(query: 'МРТ шеи', include_inactive: false, limit: 10))

      expect(payload['services'].map { |item| item['id'] }).to eq([service1.id])
    end

    it 'preserves deterministic service ordering without a query' do
      earlier_name = create(:scheduling_service, account: account, name: 'A consultation')

      payload = JSON.parse(service.execute(include_inactive: false, limit: 10))

      expect(payload['services'].map { |item| item['id'] }).to eq([earlier_name.id, service1.id])
    end
  end
end
