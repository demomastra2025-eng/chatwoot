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

  it 'lets the agent correct a call that ended in a business answer: another slot after a taken one takes the place of the receipt' do
    guard.reserve
    guard.finish(JSON.generate(success: false, reason: 'time_taken'))
    expect(session.read.fetch('operations').values).to contain_exactly(include('status' => 'finished', 'outcome' => 'not_executed'))

    corrected = described_class.new(context, tool, arguments.merge(start_at: '2026-10-15T11:00:00Z'))
    expect(corrected.reserve).to be_nil
    expect(session.read.fetch('operations').values).to contain_exactly(include('status' => 'executing'))

    corrected.finish({ success: true, data: { appointment_id: 18 } })
    expect(session.read.fetch('operations').values).to contain_exactly(include('status' => 'finished', 'outcome' => 'success'))
    # the booking that happened is claimed again: a third call is refused
    third = described_class.new(context, tool, arguments.merge(start_at: '2026-10-15T12:00:00Z')).reserve
    expect(third.dig(:audit, :failure_reason)).to eq('mutation_retry_blocked')
  end

  it 'answers the identical call after a business answer with the stored result, without executing again' do
    guard.reserve
    guard.finish({ success: false, reason: 'time_taken' })

    replay = described_class.new(context, tool, arguments).reserve

    expect(replay[:success]).to be(false)
    expect(replay.dig(:audit, :cached_result_reused)).to be(true)
  end

  it 'keeps a call that may have gone through claimed, whatever the next call asks: the provider did not answer' do
    guard.reserve
    guard.finish(Captain::ToolResult.failure(error: 'Provider did not answer', retryable: false))
    expect(session.read.fetch('operations').values).to contain_exactly(include('outcome' => 'unknown'))

    expect(described_class.new(context, tool, arguments.merge(service_id: 2)).reserve.dig(:audit, :failure_reason)).to eq('mutation_retry_blocked')
  end

  it 'keeps a call that is still executing claimed' do
    guard.reserve

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

  it 'records what an action did on its receipt: success, nothing changed, or unknown' do
    results = [
      ['create_appointment', { success: true, data: { appointment_id: 1 } }, 'success'],
      ['update_appointment', JSON.generate(success: false, reason: 'time_taken'), 'not_executed'],
      ['cancel_appointment', Captain::ToolResult.failure(error: 'Provider did not answer', retryable: false), 'unknown']
    ]

    results.each do |name, result, _expected|
      action = described_class.new(context, double('Mutation', name: name, metadata: { read_only: false }), arguments)
      action.reserve
      action.finish(result)
    end

    expect(session.read.fetch('operations').values.pluck('outcome')).to eq(results.map(&:last))
  end

  describe 'for the owner of a council part, which does not hold the conversation' do
    let(:specialist) { create(:captain_assistant, account: assistant.account) }
    let(:part_context) do
      { state: { assistant_id: specialist.id }, agent_session: session, agent_request_id: 'same-input', part_run: true,
        active_part_id: 'part-1', active_part_version: 1 }
    end

    before do
      session.change do |data|
        data['parts'] = [{ 'id' => 'part-1', 'version' => 1, 'executor_agent_id' => specialist.id, 'state' => 'open' },
                         { 'id' => 'part-2', 'version' => 1, 'executor_agent_id' => specialist.id, 'state' => 'open' }]
      end
      session.update_routing(actor_id: assistant.id)
    end

    it 'reserves the action under the scope of its part, while another agent is the current one of the conversation' do
      action = described_class.new(part_context, tool, arguments)

      expect(action.reserve).to be_nil
      expect(session.read.fetch('operations').values).to contain_exactly(
        include('status' => 'executing', 'scope' => 'part:part-1:v1', 'actor_id' => specialist.id)
      )
    end

    it 'is refused without the mark of a part: an agent that is not the current one cannot act under a part of its own' do
      part_context.delete(:part_run)

      expect { described_class.new(part_context, tool, arguments).reserve }.to raise_error(Captain::Conversation::ControlGenerationStaleError)
    end

    it 'answers the identical second call with the stored result and blocks the same tool with other arguments, in the same part' do
      first = described_class.new(part_context, tool, arguments)
      first.reserve
      first.finish({ success: true, data: { appointment_id: 17 } })

      replay = described_class.new(part_context, tool, arguments).reserve
      other = described_class.new(part_context, tool, arguments.merge(service_id: 2)).reserve

      expect(replay.dig(:audit, :cached_result_reused)).to be(true)
      expect(replay.dig(:data, :appointment_id)).to eq(17)
      expect(other.dig(:audit, :failure_reason)).to eq('mutation_retry_blocked')
    end

    it 'lets another part of the same request use the same tool: two patients, two parts' do
      first = described_class.new(part_context, tool, arguments)
      first.reserve
      first.finish({ success: true, data: { appointment_id: 17 } })

      second_part = part_context.merge(active_part_id: 'part-2')

      expect(described_class.new(second_part, tool, arguments.merge(service_id: 2)).reserve).to be_nil
    end

    it 'gives no protection to a run without the durable session, which is why a writing part is given the session' do
      bare = part_context.except(:agent_session)

      expect(described_class.new(bare, tool, arguments).reserve).to be_nil
      expect(described_class.new(bare, tool, arguments).reserve).to be_nil
      expect(session.read.fetch('operations', {})).to be_empty
    end
  end
end
