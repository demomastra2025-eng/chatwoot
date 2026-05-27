require 'rails_helper'

RSpec.describe Captain::Tools::Copilot::SearchCompaniesService do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:service) { described_class.new(assistant, user: user) }

  let!(:company1) do
    create(
      :company,
      account: account,
      name: 'OneLink Health',
      domain: 'onelink.health',
      custom_attributes: { 'segment' => 'clinic' },
      additional_attributes: { 'source' => 'captain' },
      last_activity_at: Time.zone.parse('2026-05-26 10:00:00')
    )
  end
  let!(:company2) { create(:company, account: account, name: 'OneLink Dental', domain: 'onelink.dental') }

  describe '#execute' do
    it 'returns normalized companies with filters and total_count' do
      payload = JSON.parse(service.execute(name: 'Health', limit: 1))

      expect(payload['filters']).to include('name' => 'Health')
      expect(payload['total_count']).to eq(1)
      expect(payload['companies'].length).to eq(1)
      expect(payload['companies'].map { |company| company['id'] }).not_to include(company2.id)
      expect(payload['companies'].first).to include(
        'id' => company1.id,
        'account_id' => account.id,
        'name' => 'OneLink Health',
        'domain' => 'onelink.health',
        'contacts_count' => 0,
        'custom_attributes' => { 'segment' => 'clinic' },
        'additional_attributes' => { 'source' => 'captain' },
        'last_activity_at' => company1.last_activity_at.iso8601
      )
    end
  end
end
