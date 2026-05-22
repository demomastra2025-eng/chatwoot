require 'rails_helper'

RSpec.describe Captain::Tools::Copilot::UpdateTaskService do
  let(:account) { create(:account) }
  let(:user) { create(:user, :administrator, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:contact) { create(:contact, account: account) }
  let(:conversation) { create(:conversation, account: account, contact: contact) }
  let!(:task) do
    create(
      :crm_task,
      account: account,
      originating_conversation_id: conversation.id,
      custom_attributes: { 'source' => 'site' }
    )
  end
  let(:copilot_thread) { create(:captain_copilot_thread, account: account, user: user, assistant: assistant) }
  let(:service) { described_class.new(assistant, user: user, conversation: conversation, copilot_thread: copilot_thread) }

  before do
    account.enable_features!('crm_tasks')
    create(:crm_field_definition, account: account, entity_kind: 'task', key: 'source', label: 'Source', field_type: 'text')
    create(:crm_field_definition, account: account, entity_kind: 'task', key: 'playbook', label: 'Playbook', field_type: 'text')
  end

  describe '#execute' do
    it 'updates the current task using JSON custom_attributes' do
      payload = JSON.parse(execute_confirmed(priority: 'urgent', custom_attributes: { source: 'captain', playbook: 'recovery' }.to_json))

      task.reload

      expect(payload).to include('action' => 'update_task')
      expect(payload['task']).to include('id' => task.id, 'priority' => 'urgent')
      expect(task.priority).to eq('urgent')
      expect(task.custom_attributes).to include(
        'source' => 'captain',
        'playbook' => 'recovery'
      )
    end
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
