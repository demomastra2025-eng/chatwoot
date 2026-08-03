require 'rails_helper'

RSpec.describe Captain::Tools::CreateTaskTool, type: :model do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:tool) { described_class.new(assistant) }

  before do
    account.enable_features!('crm_tasks')
  end

  it 'returns normalized create_task payload' do
    conversation = create(:conversation, account: account)
    tool_context = Struct.new(:state).new({ conversation: { id: conversation.id } })

    payload = JSON.parse(
      tool.perform(
        tool_context,
        title: 'Call client',
        activity_type: 'meeting',
        outcome: 'not_done',
        outcome_note: 'Client did not join; retry tomorrow'
      )
    )

    expect(payload).to include(
      'action' => 'create_task',
      'activity_type' => 'meeting',
      'outcome' => 'not_done',
      'outcome_note' => 'Client did not join; retry tomorrow',
      'task_id' => payload.dig('task', 'id')
    )
    expect(payload['task']).to include(
      'activity_type' => 'meeting',
      'originating_conversation_id' => conversation.id,
      'outcome' => 'not_done',
      'outcome_note' => 'Client did not join; retry tomorrow',
      'title' => 'Call client'
    )
  end

  it 'preserves explicit account-scoped deal and originating conversation links' do
    current_conversation = create(:conversation, account: account)
    linked_conversation = create(:conversation, account: account)
    deal = create(:crm_deal, account: account)
    tool_context = Struct.new(:state).new({ conversation: { id: current_conversation.id } })

    payload = JSON.parse(
      tool.perform(
        tool_context,
        title: 'Linked follow-up',
        deal_id: deal.id,
        originating_conversation_id: linked_conversation.display_id
      )
    )

    task = account.crm_tasks.find(payload.dig('task', 'id'))
    expect(task.deal_id).to eq(deal.id)
    expect(task.originating_conversation_id).to eq(linked_conversation.id)
  end
end
