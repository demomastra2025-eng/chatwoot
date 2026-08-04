require 'rails_helper'

RSpec.describe Captain::Tools::Copilot::ListSchedulingResourcesService do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:service) { described_class.new(assistant, user: user) }

  before do
    account.enable_features!('scheduling')
  end

  describe '#name' do
    it 'returns the correct service name' do
      expect(service.name).to eq('list_scheduling_resources')
    end
  end

  describe '#parameters' do
    it 'defines listing filters' do
      expect(service.parameters.keys).to contain_exactly(:service_id, :include_inactive, :limit)
    end
  end

  describe '#execute' do
    let!(:resource_a) { create(:scheduling_resource, account: account, name: 'Aidana') }
    let!(:resource_b) { create(:scheduling_resource, account: account, name: 'Bota') }
    let!(:inactive_resource) { create(:scheduling_resource, account: account, name: 'Closed', active: false) }
    let!(:service_record) { create(:scheduling_service, account: account, name: 'Consultation') }
    let!(:service_price) { create(:scheduling_service_price, service: service_record, resource: resource_b, active: true) }

    it 'lists active specialists by default' do
      payload = JSON.parse(service.execute)

      expect(payload['resources'].map { |item| item['id'] }).to contain_exactly(resource_a.id, resource_b.id)
      expect(payload['total_count']).to eq(2)
    end

    it 'filters specialists by service id' do
      payload = JSON.parse(service.execute(service_id: service_record.id))

      expect(payload['resources'].map { |item| item['id'] }).to eq([resource_b.id])
    end

    it 'treats non-positive and blank service ids as an omitted filter' do
      [0, -1, ''].each do |service_id|
        payload = JSON.parse(service.execute(service_id: service_id))

        expect(payload['service_id']).to be_nil
        expect(payload['resources'].map { |item| item['id'] }).to contain_exactly(resource_a.id, resource_b.id)
      end
    end

    it 'rejects an unknown service id instead of returning a false empty success' do
      expect(service.execute(service_id: 2_147_483_647)).to include('Unknown service_id 2147483647 for this account')
    end

    it 'includes inactive specialists when requested' do
      payload = JSON.parse(service.execute(include_inactive: true))

      expect(payload['resources'].map { |item| item['id'] }).to include(inactive_resource.id)
    end
  end
end
