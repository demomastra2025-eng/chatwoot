require 'rails_helper'

RSpec.describe Captain::Tools::Copilot::TransitionDealStageService do
  let(:account) { create(:account) }
  let(:user) { create(:user, :administrator, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:conversation) { create(:conversation, account: account) }
  let(:service) { described_class.new(assistant, user: user, conversation: conversation) }

  before do
    account.enable_features!('crm_deals')
  end

  it 'returns normalized transitioned deal payload wrapper' do
    pipeline = create(:crm_pipeline, account: account)
    old_stage = create(:crm_stage, account: account, pipeline: pipeline, name: 'New', color: '#111111')
    new_stage = create(:crm_stage, account: account, pipeline: pipeline, name: 'Qualified', code: 'qualified', color: '#222222')
    deal = create(:crm_deal, account: account, pipeline: pipeline, stage: old_stage, originating_conversation_id: conversation.id)

    payload = JSON.parse(service.execute(stage_code: 'qualified'))

    expect(payload).to include('action' => 'transition_deal_stage')
    expect(payload['deal']).to include(
      'id' => deal.id,
      'stage_id' => new_stage.id,
      'pipeline_id' => pipeline.id
    )
  end
end
