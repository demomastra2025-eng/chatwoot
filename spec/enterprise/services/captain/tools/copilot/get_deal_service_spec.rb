require 'rails_helper'

RSpec.describe Captain::Tools::Copilot::GetDealService do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:service) { described_class.new(assistant, user: user) }

  before do
    account.enable_features!('crm_deals')
  end

  it 'returns a normalized deal payload' do
    company = create(:company, account: account, name: 'OneLink')
    pipeline = create(:crm_pipeline, account: account)
    stage = create(:crm_stage, account: account, pipeline: pipeline, name: 'Qualified')
    deal = create(:crm_deal, account: account, title: 'Enterprise renewal', company: company, pipeline: pipeline, stage: stage)

    payload = JSON.parse(service.execute(deal_id: deal.id))

    expect(payload['deal']).to include(
      'id' => deal.id,
      'title' => 'Enterprise renewal',
      'company_id' => company.id,
      'pipeline_id' => pipeline.id,
      'stage_id' => stage.id
    )
  end

  it 'rejects invalid deal IDs instead of silently returning not found' do
    expect { service.execute(deal_id: { name: 'get_deal', parameters: { wrong_id: 52 } }) }
      .to raise_error(ArgumentError, 'deal_id is required')
  end

  it 'returns a structured failure when the deal is missing' do
    expect(service.execute(deal_id: 999)).to eq('ERROR: Deal not found')
  end

  it 'fetches a summarized deal by its exact ID while refusing another patient card' do
    conversation = create(:conversation, account: account)
    own = create(:crm_deal, account: account, title: 'Own summarized deal')
    other = create(:crm_deal, account: account, title: 'Other patient deal')
    create(:crm_deal_contact, account: account, deal: own, contact: conversation.contact)
    create(:crm_deal_contact, account: account, deal: other)
    service.patient_scope = Captain::Tools::Agent::PatientScope.new(assistant: assistant, conversation: conversation)
    summary = Captain::DealContext.new(account: account, conversation: conversation).summary
    selected_id = summary[:groups].first[:items].first[:id]

    expect(JSON.parse(service.execute(deal_id: selected_id))['deal']).to include('id' => own.id, 'title' => own.title)
    expect(service.execute(deal_id: other.id)).to eq(Captain::Tools::Agent::PatientScope::FAILURE)
  end
end
