require 'rails_helper'

RSpec.describe Captain::Tools::Copilot::AddDealCommentService do
  let(:account) { create(:account) }
  let(:user) { create(:user, :administrator, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:conversation) { create(:conversation, account: account) }
  let(:service) { described_class.new(assistant, user: user, conversation: conversation) }

  before do
    account.enable_features!('crm_deals')
  end

  it 'returns a normalized deal comment payload' do
    pipeline = create(:crm_pipeline, account: account)
    stage = create(:crm_stage, account: account, pipeline: pipeline)
    deal = create(:crm_deal, account: account, pipeline: pipeline, stage: stage, originating_conversation_id: conversation.id)

    payload = JSON.parse(service.execute(body: 'Deal follow-up', deal_id: deal.id))

    expect(payload).to include(
      'action' => 'add_deal_comment',
      'deal_id' => deal.id
    )
    expect(payload.fetch('comment')).to include('body' => 'Deal follow-up', 'user_id' => user.id)
  end

  it 'requires a specific deal instead of selecting one from the conversation' do
    deal = create(:crm_deal, account: account, originating_conversation: conversation)

    expect { service.execute(body: 'Follow-up') }.not_to change(deal.comments, :count)
    expect(service.execute(body: 'Follow-up')).to include('deal_id is required')
  end
end
