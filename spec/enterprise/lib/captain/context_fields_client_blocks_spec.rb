require 'rails_helper'

RSpec.describe Captain::ContextFields do
  let(:account) { create(:account) }
  let(:contact) { create(:contact, account: account) }
  let(:conversation) { create(:conversation, account: account, contact: contact) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:pipeline) { create(:crm_pipeline, account: account) }
  let(:open_stage) { create(:crm_stage, account: account, pipeline: pipeline, outcome: 'open') }
  let(:won_stage) { create(:crm_stage, account: account, pipeline: pipeline, outcome: 'won') }
  let(:lost_stage) { create(:crm_stage, account: account, pipeline: pipeline, outcome: 'lost') }

  before { account.enable_features!('crm_deals') }

  def linked_deal(stage:, **attributes)
    deal = create(:crm_deal, account: account, pipeline: pipeline, stage: stage, **attributes)
    create(:crm_deal_contact, account: account, deal: deal, contact: contact)
    deal
  end

  it 'renders open, last won and last lost deals with counts for only this contact' do
    open = linked_deal(stage: open_stage)
    won = linked_deal(stage: won_stage, closed_at: 1.day.ago)
    lost = linked_deal(stage: lost_stage, closed_at: 2.days.ago)
    create(:crm_deal, account: account, pipeline: pipeline, stage: open_stage)

    fields = described_class.definitions_for(account)
    expect(fields.pluck(:id)).to include('deal.client_deals', 'deal.summary')
    state = { conversation: { id: conversation.id, contact_id: contact.id } }
    prompt = described_class.prompt_state_for(
      assistant: assistant, runtime_state: state, field_ids: %w[deal.client_deals]
    )
    block = prompt.dig(:deal, 'client_deals')

    expect(block[:counts]).to eq('open' => 1, 'won' => 1, 'lost' => 1)
    expect(block[:groups].map { |group| [group[:status], group[:deals].pluck(:id)] })
      .to eq([['open', [open.id]], ['won', [won.id]], ['lost', [lost.id]]])
  end

  it 'renders the reply notification only when the selected field has a stored link' do
    payload = { kind: 'reminder', reminder_id: 42 }
    state = { conversation: { id: conversation.id, reply_notification: payload } }
    prompt = described_class.prompt_state_for(
      assistant: assistant, runtime_state: state, field_ids: %w[conversation.reply_notification]
    )

    expect(described_class.field_ids_for(account)).to include('conversation.reply_notification')
    expect(prompt.dig(:conversation, 'reply_notification')).to eq(payload)
    expect(prompt.dig(:conversation, 'reply_notification')).not_to be_nil
  end
end
