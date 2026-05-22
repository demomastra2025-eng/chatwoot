require 'rails_helper'

RSpec.describe Captain::Tools::Copilot::ChangeTaskStatusService do
  let(:account) { create(:account) }
  let(:user) { create(:user, :administrator, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:conversation) { create(:conversation, account: account) }
  let(:copilot_thread) { create(:captain_copilot_thread, account: account, user: user, assistant: assistant) }
  let(:service) { described_class.new(assistant, user: user, conversation: conversation, copilot_thread: copilot_thread) }

  before do
    account.enable_features!('crm_tasks')
  end

  it 'returns normalized task status transition payload wrapper' do
    old_status = create(:crm_task_status, account: account, name: 'Todo', code: 'todo')
    new_status = create(:crm_task_status, account: account, name: 'Done', code: 'done')
    task = create(:crm_task, account: account, status: old_status, originating_conversation_id: conversation.id)

    payload = JSON.parse(execute_confirmed(status_code: 'done'))

    expect(payload).to include('action' => 'change_task_status', 'task_id' => task.id, 'status_id' => new_status.id)
    expect(payload['task']).to include(
      'id' => task.id,
      'status_id' => new_status.id
    )
  end

  def execute_confirmed(**arguments)
    first_result = service.execute(**arguments)
    first_payload = JSON.parse(first_result)
    return first_result unless first_payload.dig('data', 'confirmation_required')

    confirmation_token = copilot_thread.copilot_messages.assistant_thinking.last.message.dig('confirmation_gate', 'confirmation_token')

    create(
      :captain_copilot_message,
      account: account,
      copilot_thread: copilot_thread,
      message_type: 'user',
      message: { 'content' => "Подтверждаю #{confirmation_token}" }
    )

    service.execute(**arguments)
  end
end
