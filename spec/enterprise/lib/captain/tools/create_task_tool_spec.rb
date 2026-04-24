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

    payload = JSON.parse(tool.perform(tool_context, title: 'Call client'))

    expect(payload).to include('action' => 'create_task')
    expect(payload['task']).to include('title' => 'Call client', 'originating_conversation_id' => conversation.id)
  end
end
