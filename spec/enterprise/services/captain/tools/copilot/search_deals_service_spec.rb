require 'rails_helper'

RSpec.describe Captain::Tools::Copilot::SearchDealsService do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:service) { described_class.new(assistant, user: user) }
  let(:conversation) { create(:conversation, account: account) }
  let(:conversation_service) { described_class.new(assistant, user: user, conversation: conversation) }
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
    it 'returns normalized deals with filters and returned_count' do
      payload = JSON.parse(service.execute(query: 'renewal', company_id: company.id, limit: 1))

      expect(payload['filters']).to include('query' => 'renewal', 'company_id' => company.id)
      expect(payload['returned_count']).to eq(1)
      expect(payload['deals'].length).to eq(1)
      expect(payload['deals'].first).to include(
        'id' => deal1.id,
        'title' => 'Enterprise renewal',
        'company_id' => company.id
      )
    end

    it 'filters deals by pipeline and stage identifiers without relying on duplicate stage names' do
      other_pipeline = create(:crm_pipeline, account: account, code: 'andalusiya')
      duplicate_stage = create(:crm_stage, account: account, pipeline: other_pipeline, name: 'Qualified', code: 'qualified', color: '#111111')
      other_deal = create(:crm_deal, account: account, title: 'Other pipeline deal', pipeline: other_pipeline, stage: duplicate_stage)

      by_pipeline = JSON.parse(service.execute(pipeline_id: pipeline.id))
      by_stage = JSON.parse(service.execute(pipeline_code: pipeline.code.titleize, stage_code: stage.code.titleize))

      expect(by_pipeline['filters']).to include('pipeline_id' => pipeline.id)
      expect(by_pipeline['deals'].map { |deal| deal['id'] }).to include(deal1.id, deal2.id)
      expect(by_pipeline['deals'].map { |deal| deal['id'] }).not_to include(other_deal.id)

      expect(by_stage['filters']).to include('pipeline_code' => pipeline.code.titleize, 'stage_code' => stage.code.titleize)
      expect(by_stage['deals'].map { |deal| deal['id'] }).to contain_exactly(deal1.id, deal2.id)
    end

    it 'defaults blank conversation searches to current contact deals and hides internal amount_minor' do
      contact_deal = create(:crm_deal, account: account, title: 'Current contact deal', pipeline: pipeline, stage: stage, amount_minor: 2_500_000,
                                       currency: 'KZT')
      create(:crm_deal_contact, account: account, deal: contact_deal, contact: conversation.contact, primary: true)
      other_contact_deal = create(:crm_deal, account: account, title: 'Other contact deal', pipeline: pipeline, stage: stage)
      create(:crm_deal_contact, account: account, deal: other_contact_deal)

      payload = JSON.parse(
        conversation_service.execute(
          query: '',
          pipeline_id: 0,
          stage_id: 0,
          owner_id: 0,
          company_id: 0,
          limit: 10
        )
      )

      expect(payload['filters']).to include('current_contact_id' => conversation.contact_id)
      expect(payload['deals'].map { |deal| deal['id'] }).to include(contact_deal.id)
      expect(payload['deals'].map { |deal| deal['id'] }).not_to include(other_contact_deal.id)
      expect(payload['deals'].first).not_to have_key('amount_minor')
      expect(payload['deals'].find { |deal| deal['id'] == contact_deal.id }['amount']).to eq('25000')
    end
  end
end
