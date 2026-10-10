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
    it 'pages every matching deal with deterministic order and preserves the existing result keys' do
      53.times { |index| create(:crm_deal, account: account, pipeline: pipeline, stage: stage, title: "Paged #{index}", updated_at: 1.day.ago) }
      first = JSON.parse(service.execute(query: 'Paged', limit: 50, offset: 0))
      second = JSON.parse(service.execute(query: 'Paged', limit: 50, offset: first['next_offset']))

      expect(first).to include('total_count' => 53, 'shown' => 50, 'has_more' => true, 'next_offset' => 50)
      expect(second).to include('total_count' => 53, 'shown' => 3, 'has_more' => false, 'next_offset' => nil)
      expect(first['deals'].pluck('id') & second['deals'].pluck('id')).to be_empty
      expect((first['deals'] + second['deals']).pluck('id')).to eq(account.crm_deals.where('title LIKE ?', 'Paged%').order(id: :desc).pluck(:id))
      expect(service.execute(offset: -1)).to include('offset must be a non-negative integer')
    end

    it 'filters active, closed and archived deals without requiring a page-wide history load' do
      closed = create(:crm_deal, account: account, pipeline: pipeline, stage: stage, closed_at: 1.day.ago)
      archived = create(:crm_deal, account: account, pipeline: pipeline, stage: stage, archived_at: 1.day.ago)

      expect(JSON.parse(service.execute(status: 'active'))['deals'].pluck('id')).to contain_exactly(deal1.id, deal2.id)
      expect(JSON.parse(service.execute(status: 'closed'))['deals'].pluck('id')).to eq([closed.id])
      expect(JSON.parse(service.execute(status: 'archived'))['deals'].pluck('id')).to eq([archived.id])
      expect(JSON.parse(service.execute(status: 'any'))['total_count']).to eq(4)
      expect(service.execute(status: 'unknown')).to include('status must be active')
    end

    it 'keeps patient title searches and pages restricted to the same exact contact as the summary' do
      own = create(:crm_deal, account: account, pipeline: pipeline, stage: stage, title: 'Shared title')
      other = create(:crm_deal, account: account, pipeline: pipeline, stage: stage, title: 'Shared title')
      create(:crm_deal_contact, account: account, deal: own, contact: conversation.contact)
      create(:crm_deal_contact, account: account, deal: other)
      conversation_service.patient_scope = Captain::Tools::Agent::PatientScope.new(assistant: assistant, conversation: conversation)
      payload = JSON.parse(conversation_service.execute(query: 'Shared title', status: 'any', offset: 0))

      expect(payload['deals'].pluck('id')).to eq([own.id])
      expect(payload['total_count']).to eq(1)
      expect(JSON.parse(conversation_service.execute(query: 'Shared title', offset: 1))['deals']).to be_empty
      expect(conversation_service.execute(contact_id: create(:contact, account: account).id)).to eq(Captain::Tools::Agent::PatientScope::FAILURE)
    end

    it 'returns normalized deals with filters and total_count before limit' do
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

    it 'keeps total_count independent from the requested limit' do
      payload = JSON.parse(service.execute(pipeline_id: pipeline.id, limit: 1))

      expect(payload['total_count']).to eq(2)
      expect(payload['deals'].length).to eq(1)
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

      expect(by_stage['filters']).to include('pipeline_code' => pipeline.code, 'stage_code' => stage.code)
      expect(by_stage['deals'].map { |deal| deal['id'] }).to contain_exactly(deal1.id, deal2.id)
    end

    it 'prefers verified semantic pipeline and stage selectors over conflicting ids' do
      other_pipeline = create(:crm_pipeline, account: account, code: 'other')
      other_stage = create(:crm_stage, account: account, pipeline: other_pipeline, name: 'Other', code: 'other')

      payload = JSON.parse(service.execute(
                             pipeline_id: other_pipeline.id,
                             pipeline_code: pipeline.code,
                             stage_id: other_stage.id,
                             stage_name: stage.name
                           ))

      expect(payload['filters']).to include('pipeline_id' => pipeline.id, 'stage_id' => stage.id)
      expect(payload['deals'].map { |deal| deal['id'] }).to contain_exactly(deal1.id, deal2.id)
    end

    it 'rejects every unknown entity id filter instead of returning a false empty success' do
      %i[contact_id pipeline_id stage_id owner_id company_id].each do |field_name|
        expect(service.execute(field_name => 2_147_483_647)).to include("Unknown #{field_name} 2147483647 for this account")
      end
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

    it 'searches the whole account by title when the current contact is unrelated' do
      account_deal = create(:crm_deal, account: account, title: 'Account-wide renewal', pipeline: pipeline, stage: stage)
      current_contact_deal = create(:crm_deal, account: account, title: 'Current contact only', pipeline: pipeline, stage: stage)
      create(:crm_deal_contact, account: account, deal: current_contact_deal, contact: conversation.contact, primary: true)

      payload = JSON.parse(conversation_service.execute(query: 'Account-wide renewal'))

      expect(payload['filters']).to include('query' => 'Account-wide renewal')
      expect(payload['filters']).not_to have_key('current_contact_id')
      expect(payload['deals'].map { |deal| deal['id'] }).to contain_exactly(account_deal.id)
    end

    it 'keeps an explicit contact filter when searching by title' do
      target_contact = create(:contact, account: account)
      linked_deal = create(:crm_deal, account: account, title: 'Shared title', pipeline: pipeline, stage: stage)
      unlinked_deal = create(:crm_deal, account: account, title: 'Shared title', pipeline: pipeline, stage: stage)
      create(:crm_deal_contact, account: account, deal: linked_deal, contact: target_contact, primary: true)

      payload = JSON.parse(conversation_service.execute(query: 'Shared title', contact_id: target_contact.id))

      expect(payload['filters']).to include('query' => 'Shared title', 'contact_id' => target_contact.id)
      expect(payload['deals'].map { |deal| deal['id'] }).to contain_exactly(linked_deal.id)
      expect(payload['deals'].map { |deal| deal['id'] }).not_to include(unlinked_deal.id)
    end
  end
end
