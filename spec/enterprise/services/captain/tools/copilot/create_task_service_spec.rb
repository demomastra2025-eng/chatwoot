require 'rails_helper'

RSpec.describe Captain::Tools::Copilot::CreateTaskService do
  let(:account) { create(:account) }
  let(:user) { create(:user, :administrator, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:contact) { create(:contact, account: account) }
  let(:conversation) { create(:conversation, account: account, contact: contact) }
  let!(:deal) { create(:crm_deal, account: account, originating_conversation_id: conversation.id) }
  let(:copilot_thread) { create(:captain_copilot_thread, account: account, user: user, assistant: assistant) }
  let(:service) { described_class.new(assistant, user: user, conversation: conversation, copilot_thread: copilot_thread) }

  before do
    account.enable_features!('crm_tasks')
    account.enable_features!('crm_deals')
    create(:crm_field_definition, account: account, entity_kind: 'task', key: 'source', label: 'Source', field_type: 'text')
    create(:crm_field_definition, account: account, entity_kind: 'task', key: 'channel', label: 'Channel', field_type: 'text')
    confirmation_gate = instance_double(Captain::Copilot::ToolConfirmationGate, call: nil)
    allow(Captain::Copilot::ToolConfirmationGate).to receive(:new).and_return(confirmation_gate)
  end

  describe '#execute' do
    it 'creates a task using JSON custom_attributes' do
      payload = JSON.parse(
        execute_confirmed(
          title: 'Call back tomorrow',
          priority: 'high',
          custom_attributes: { source: 'captain', channel: 'telegram' }.to_json
        )
      )

      task = account.crm_tasks.order(:id).last

      expect(payload).to include('action' => 'create_task', 'task_id' => task.id)
      expect(payload['task']).to include('id' => task.id, 'title' => 'Call back tomorrow', 'priority' => 'high')
      expect(task.title).to eq('Call back tomorrow')
      expect(task.priority).to eq('high')
      expect(task.deal_id).to eq(deal.id)
      expect(task.originating_conversation_id).to eq(conversation.id)
      expect(task.custom_attributes).to include(
        'source' => 'captain',
        'channel' => 'telegram'
      )
    end

    it 'creates a task linked to explicit deal, conversation, assignee, team, and status' do
      target_conversation = create(:conversation, account: account)
      target_deal = create(:crm_deal, account: account, originating_conversation_id: target_conversation.id)
      status = create(:crm_task_status, account: account, name: 'Next', code: 'next', category: 'open')
      assignee = create(:user, account: account)
      team = create(:team, account: account)

      service.execute(
        title: 'Prepare proposal',
        deal_id: target_deal.id,
        originating_conversation_id: target_conversation.display_id,
        status_id: status.id,
        assignee_id: assignee.id,
        team_id: team.id
      )

      task = account.crm_tasks.order(:id).last
      expect(task.title).to eq('Prepare proposal')
      expect(task.deal_id).to eq(target_deal.id)
      expect(task.originating_conversation_id).to eq(target_conversation.id)
      expect(task.status_id).to eq(status.id)
      expect(task.assignee_id).to eq(assignee.id)
      expect(task.team_id).to eq(team.id)
    end

    it 'does not link tasks to another account conversation' do
      other_conversation = create(:conversation, account: create(:account))

      result = service.execute(title: 'Invalid link', originating_conversation_id: other_conversation.id)

      expect(result).to include('Conversation not found')
      expect(account.crm_tasks.find_by(title: 'Invalid link')).to be_nil
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
