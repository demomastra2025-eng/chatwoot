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
end
