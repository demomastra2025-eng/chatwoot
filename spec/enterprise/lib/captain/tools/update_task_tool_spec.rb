require 'rails_helper'

RSpec.describe Captain::Tools::UpdateTaskTool, type: :model do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:tool) { described_class.new(assistant) }

  before do
    account.enable_features!('crm_tasks')
  end

  it 'returns normalized update_task payload' do
    conversation = create(:conversation, account: account)
    status = create(:crm_task_status, account: account)
    task = create(:crm_task, account: account, title: 'Old task', status: status, originating_conversation_id: conversation.id)
    tool_context = Struct.new(:state).new({ conversation: { id: conversation.id }, task: { id: task.id } })

    payload = JSON.parse(
      tool.perform(
        tool_context,
        title: 'New task',
        activity_type: 'call',
        all_day: true,
        due_on: '2026-09-04',
        schedule_timezone: 'Asia/Almaty',
        outcome: 'not_done',
        outcome_note: 'Client was unavailable; retry tomorrow'
      )
    )

    expect(payload).to include(
      'action' => 'update_task',
      'activity_type' => 'call',
      'all_day' => true,
      'due_on' => '2026-09-04',
      'outcome' => 'not_done',
      'outcome_note' => 'Client was unavailable; retry tomorrow',
      'task_id' => task.id,
      'status_id' => status.id
    )
    expect(payload['task']).to include(
      'activity_type' => 'call',
      'all_day' => true,
      'due_at' => nil,
      'due_on' => '2026-09-04',
      'id' => task.id,
      'outcome' => 'not_done',
      'outcome_note' => 'Client was unavailable; retry tomorrow',
      'schedule_timezone' => 'Asia/Almaty',
      'title' => 'New task'
    )
  end

  it 'updates an explicit account task when the current conversation has no linked task' do
    conversation = create(:conversation, account: account)
    status = create(:crm_task_status, account: account)
    task = create(:crm_task, account: account, status: status, description: 'Old description')
    tool_context = Struct.new(:state).new({ conversation: { id: conversation.id } })

    payload = JSON.parse(
      tool.perform(
        tool_context,
        task_id: task.id,
        description: 'New description'
      )
    )

    expect(payload).to include('action' => 'update_task', 'task_id' => task.id)
    expect(task.reload.description).to eq('New description')
  end

  it 'does not fall back to the current task when task_id is explicitly null' do
    conversation = create(:conversation, account: account)
    task = create(:crm_task, account: account, description: 'Original', originating_conversation_id: conversation.id)
    tool_context = Struct.new(:state).new({ conversation: { id: conversation.id }, task: { id: task.id } })

    result = tool.perform(tool_context, task_id: nil, description: 'Forbidden fallback')

    expect(result).to include('task_id must be a positive integer')
    expect(task.reload.description).to eq('Original')
  end

  it 'does not update a task from another account' do
    conversation = create(:conversation, account: account)
    foreign_task = create(:crm_task, account: create(:account))
    tool_context = Struct.new(:state).new({ conversation: { id: conversation.id } })

    result = tool.perform(tool_context, task_id: foreign_task.id, description: 'Forbidden update')

    expect(result).to include('Couldn\'t find Crm::Task')
    expect(foreign_task.reload.description).not_to eq('Forbidden update')
  end
end
