require 'rails_helper'

RSpec.describe Captain::Tools::Copilot::GetDealTimelineService do
  let(:account) { create(:account) }
  let(:user) { create(:user, :administrator, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:service) { described_class.new(assistant, user: user) }

  before do
    account.enable_features!('crm_deals')
  end

  it 'returns a normalized deal timeline payload' do
    pipeline = create(:crm_pipeline, account: account)
    stage = create(:crm_stage, account: account, pipeline: pipeline)
    deal = create(:crm_deal, account: account, pipeline: pipeline, stage: stage)
    comment = create(:crm_comment, account: account, commentable: deal, user: user, body: 'First note')

    payload = JSON.parse(service.execute(deal_id: deal.id, limit: 5))

    expect(payload).to include('deal_id' => deal.id)
    expect(payload.fetch('meta')).to include('count' => 1)
    expect(payload.fetch('items').first).to include(
      'item_type' => 'comment',
      'payload' => include('id' => comment.id, 'body' => 'First note')
    )
  end

  it 'returns a structured failure when the deal is missing' do
    expect(service.execute(deal_id: 999)).to eq('ERROR: Deal not found')
  end
end
