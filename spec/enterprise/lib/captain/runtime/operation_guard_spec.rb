require 'rails_helper'

RSpec.describe Captain::Runtime::OperationGuard do
  let(:assistant) { create(:captain_assistant) }
  let(:conversation) { create(:conversation, account: assistant.account) }
  let(:session) { Captain::Conversation::AgentSession.new(entry: assistant, conversation: conversation) }
  let(:context) { { state: { assistant_id: assistant.id }, agent_session: session, agent_request_id: 'same-input' } }
  let(:tool) { double('Mutation', name: 'create_appointment', metadata: { read_only: false }) }
  let(:arguments) { { service_id: 1, start_at: '2026-10-15T10:00:00Z' } }
  let(:guard) { described_class.new(context, tool, arguments) }

  it 'reuses the completed outcome after a worker retry without executing again' do
    expect(guard.reserve).to be_nil
    guard.finish({ success: true, data: { appointment_id: 17 } })
    result = described_class.new(context.deep_dup, tool, arguments).reserve
    expect(result.dig(:audit, :cached_result_reused)).to be(true)
    expect(result.dig(:data, :appointment_id)).to eq(17)
  end

  it 'blocks uncertain outcomes and changed arguments instead of resending to a provider' do
    guard.reserve
    expect(described_class.new(context.deep_dup, tool, arguments).reserve.dig(:audit, :failure_reason)).to eq('mutation_retry_blocked')
    guard.finish({ success: true, data: { appointment_id: 17 } })
    changed = described_class.new(context, tool, arguments.merge(service_id: 2)).reserve
    expect(changed.dig(:audit, :failure_reason)).to eq('mutation_retry_blocked')
  end

  it 'never replays another agent private action payload after a handoff' do
    guard.reserve
    guard.finish({ success: true, data: { restricted_text: 'PRIVATE' } })
    context[:state][:assistant_id] += 1
    result = described_class.new(context, tool, arguments).reserve
    expect(result.to_json).not_to include('PRIVATE')
    expect(result.dig(:audit, :failure_reason)).to eq('mutation_retry_blocked')
  end

  it 'permits another distinct customer request and preserves the shared session through context copies' do
    guard.reserve
    guard.finish({ success: true })
    copied = context.deep_dup
    expect(copied[:agent_session]).to equal(session)
    copied[:agent_request_id] = 'next-input'
    expect(described_class.new(copied, tool, arguments).reserve).to be_nil
  end

  it 'allows corrected arguments only after validation proved no mutation began' do
    guard.reserve
    guard.finish({ success: false, audit: { mutation_executed: false, failure_stage: 'tool_arguments' } })
    corrected = described_class.new(context, tool, arguments.merge(service_id: 2))
    expect(corrected.reserve).to be_nil
    corrected.finish({ success: true, data: { appointment_id: 18 } })
    expect(described_class.new(context, tool, arguments).reserve.dig(:audit, :failure_reason)).to eq('mutation_retry_blocked')
  end

  it 'keeps failed provider actions claimed even with an input-looking failure code' do
    guard.reserve
    guard.finish({ success: false, reason: 'unknown_service' })
    expect(described_class.new(context, tool, arguments.merge(service_id: 2)).reserve.dig(:audit, :failure_reason)).to eq('mutation_retry_blocked')
  end

  it 'cannot repeat completed task actions through a fresh request scope after the queue finishes' do
    context[:agent_graph] = [{ id: assistant.id }]
    queue = Captain::Runtime::TaskQueue.new(context)
    queue.create([{ title: 'First booking', assistant_id: assistant.id }, { title: 'Second booking', assistant_id: assistant.id }])
    2.times do |index|
      action = described_class.new(context, tool, arguments)
      expect(action.reserve).to be_nil
      action.finish({ success: true, data: { appointment_id: index + 17 } })
      queue.update(id: queue.active['id'], status: 'completed')
    end
    expect(queue.active).to be_nil
    repeated = described_class.new(context, tool, arguments).reserve
    expect(repeated.dig(:audit, :failure_reason)).to eq('mutation_retry_blocked')
    [Captain::Tools::HandoffTool, Captain::Tools::ResolveConversationTool].each do |tool_class|
      expect(described_class.new(context, tool_class.new(assistant), {}).reserve).to be_nil
    end
  end

  it 'explains a waiting task without claiming a provider action started and permits an explicit valid resume' do
    context[:agent_graph] = [{ id: assistant.id }]
    queue = Captain::Runtime::TaskQueue.new(context)
    queue.create([{ title: 'Own appointment', assistant_id: assistant.id }, { title: 'Relative identity', assistant_id: assistant.id }])
    own_id = queue.active['id']
    queue.update(id: own_id, status: 'waiting', result: 'Waiting for a selected time')
    queue.update(id: queue.active['id'], status: 'waiting', result: 'Waiting for relative identity')

    blocked = described_class.new(context, tool, arguments).reserve
    expect(blocked.dig(:audit, :failure_reason)).to eq('agent_task_not_active')
    expect(blocked.dig(:audit, :mutation_executed)).to be(false)
    expect(blocked[:error]).to include('was not started')
    expect(session.read.fetch('operations', {})).to be_empty

    queue.update(id: own_id, status: 'active', result: 'Customer selected a verified time')
    resumed = described_class.new(context, tool, arguments)
    expect(resumed.reserve).to be_nil
    resumed.finish({ success: true, data: { appointment_id: 17 } })
    expect(session.read.fetch('operations').size).to eq(1)
    expect(queue.tasks.map { |task| task['status'] }).to eq(%w[active waiting])
  end
end
