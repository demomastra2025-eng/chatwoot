require 'rails_helper'

RSpec.describe Captain::Tools::Copilot::SearchSchedulingResourcesService do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:service) { described_class.new(assistant, user: user) }

  before do
    account.enable_features!('scheduling')
  end

  describe '#name' do
    it 'returns the correct service name' do
      expect(service.name).to eq('search_scheduling_resources')
    end
  end

  describe '#parameters' do
    it 'defines the specialist search parameters' do
      expect(service.parameters.keys).to contain_exactly(
        :query,
        :search_by,
        :service_id,
        :include_inactive,
        :limit
      )
    end
  end

  describe '#execute' do
    let!(:therapist) do
      create(:scheduling_resource, account: account, name: 'Aigerim Sarsembayeva', specialty: 'Therapist')
    end
    let!(:cosmetologist) do
      create(:scheduling_resource, account: account, name: 'Dana Nur', specialty: 'Cosmetologist')
    end
    let!(:inactive_resource) do
      create(:scheduling_resource, account: account, name: 'Old Specialist', specialty: 'Therapist', active: false)
    end
    let!(:service_record) do
      create(:scheduling_service, account: account, name: 'Initial consultation', duration_min: 45)
    end
    let!(:service_price) do
      create(:scheduling_service_price, service: service_record, resource: therapist, active: true)
    end

    it 'returns active specialists when query is blank' do
      payload = JSON.parse(service.execute)

      expect(payload['total_count']).to eq(2)
      expect(payload['resources'].map { |item| item['id'] }).to contain_exactly(therapist.id, cosmetologist.id)
    end

    it 'filters by specialist name' do
      payload = JSON.parse(service.execute(query: 'aigerim', search_by: 'name'))

      expect(payload['resources'].map { |item| item['id'] }).to eq([therapist.id])
    end

    it 'filters by specialization' do
      payload = JSON.parse(service.execute(query: 'cosmet', search_by: 'specialty'))

      expect(payload['resources'].map { |item| item['id'] }).to eq([cosmetologist.id])
    end

    it 'filters by service availability for the specialist' do
      payload = JSON.parse(service.execute(service_id: service_record.id))

      expect(payload['filters']).to include('service_id' => service_record.id, 'search_by' => 'all', 'include_inactive' => false)
      expect(payload['resources'].map { |item| item['id'] }).to eq([therapist.id])
    end

    it 'treats non-positive and blank service ids as an omitted filter' do
      [0, -1, ''].each do |service_id|
        payload = JSON.parse(service.execute(service_id: service_id))

        expect(payload.dig('filters', 'service_id')).to be_nil
        expect(payload['resources'].map { |item| item['id'] }).to contain_exactly(therapist.id, cosmetologist.id)
      end
    end

    it 'rejects an unknown service id instead of returning a false empty success' do
      expect(service.execute(service_id: 2_147_483_647)).to include('Unknown service_id 2147483647 for this account')
    end

    it 'can include inactive specialists when requested' do
      payload = JSON.parse(service.execute(include_inactive: true, query: 'old'))

      expect(payload['resources'].map { |item| item['id'] }).to eq([inactive_resource.id])
    end

    it 'caps results by limit' do
      payload = JSON.parse(service.execute(limit: 1))

      expect(payload['resources'].length).to eq(1)
    end
  end
end
