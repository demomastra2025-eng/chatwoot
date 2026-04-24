require 'rails_helper'

RSpec.describe Captain::Tools::Copilot::SearchDealsService do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:service) { described_class.new(assistant, user: user) }
  let(:company) { create(:company, account: account) }
  let(:owner) { create(:user, account: account) }
  let(:pipeline) { create(:crm_pipeline, account: account) }
  let(:stage) { create(:crm_stage, account: account, pipeline: pipeline, name: 'Qualified') }
  let!(:deal1) { create(:crm_deal, account: account, title: 'Enterprise renewal', company: company, owner: owner, pipeline: pipeline, stage: stage) }
  let!(:deal2) { create(:crm_deal, account: account, title: 'SMB pilot', pipeline: pipeline, stage: stage) }

  before do
    account.enable_features!('crm_deals')
  end

  describe '#execute' do
    it 'returns normalized deals with filters and total_count' do
      payload = JSON.parse(service.execute(query: 'renewal', company_id: company.id, limit: 1))

      expect(payload['filters']).to include('query' => 'renewal', 'company_id' => company.id)
      expect(payload['total_count']).to eq(1)
      expect(payload['deals'].length).to eq(1)
      expect(payload['deals'].first).to include(
        'id' => deal1.id,
        'title' => 'Enterprise renewal',
        'company_id' => company.id
      )
    end
  end
end
