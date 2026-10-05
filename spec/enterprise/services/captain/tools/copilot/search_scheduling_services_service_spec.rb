require 'rails_helper'

RSpec.describe Captain::Tools::Copilot::SearchSchedulingServicesService do
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
      payload = JSON.parse(service.execute(query: 'Consult', include_inactive: false, limit: 1))

      expect(payload['filters']).to include('query' => 'Consult', 'include_inactive' => false)
      expect(payload['total_count']).to eq(1)
      expect(payload['services'].length).to eq(1)
      expect(payload['services'].first).to include(
        'id' => service1.id,
        'name' => 'Consultation',
        'active' => true
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

    it 'ranks all query concepts in the service name before metadata matches and before limiting' do
      service1.update!(name: 'МРТ Кисть левая')
      55.times do |index|
        create(:scheduling_service, account: account, name: "Обследование #{index}", category: 'МРТ кисти')
      end

      payload = JSON.parse(service.execute(query: 'МРТ кисти', limit: 1))

      expect(payload['total_count']).to be > 50
      expect(payload['services'].first['id']).to eq(service1.id)
      expect(payload).to include('returned_count' => 1, 'has_more' => true, 'match_status' => 'ambiguous')
    end

    it 'paginates ranked candidates and marks incomplete text matches as unverified' do
      next_service = create(:scheduling_service, account: account, name: 'Consultation follow-up')

      first_page = JSON.parse(service.execute(query: 'consultation', limit: 1))
      next_page = JSON.parse(service.execute(query: 'consultation', limit: 1, offset: first_page['next_offset']))

      expect(first_page['services'].first['id']).to eq(service1.id)
      expect(next_page['services'].first['id']).to eq(next_service.id)
      expect(next_page).to include('next_offset' => nil, 'returned_count' => 1)
      out_of_range = JSON.parse(service.execute(query: 'consultation', offset: 100))
      expect(out_of_range).to include('total_count' => 2, 'returned_count' => 0, 'page_status' => 'offset_out_of_range')

      partial = JSON.parse(service.execute(query: 'Consultation dentist', limit: 1))
      expect(partial).to include('match_status' => 'partial_candidates', 'eligibility_status' => 'unverified')
    end

    it 'does not reveal another account service or accept an invalid pagination offset' do
      other_account = create(:account)
      create(:scheduling_service, account: other_account, name: 'МРТ кисти')

      payload = JSON.parse(service.execute(query: 'МРТ кисти'))
      expect(payload).to include('total_count' => 0, 'match_status' => 'no_match')
      expect(service.execute(query: 'Consultation', offset: -1)).to include('offset must be a non-negative integer')
    end

    it 'preserves deterministic service ordering without a query' do
      earlier_name = create(:scheduling_service, account: account, name: 'A consultation')

      payload = JSON.parse(service.execute(include_inactive: false, limit: 10))

      expect(payload['services'].map { |item| item['id'] }).to eq([earlier_name.id, service1.id])
    end
  end
end
