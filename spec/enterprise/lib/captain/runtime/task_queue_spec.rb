require 'rails_helper'

RSpec.describe Captain::Runtime::TaskQueue do
  let(:entry) { create(:captain_assistant) }
  let(:session) { Captain::Conversation::AgentSession.new(entry: entry) }
  let(:context) do
    { state: { assistant_id: entry.id }, agent_request_id: 'request-1', agent_session: session,
      agent_graph: [{ id: entry.id }, { id: entry.id + 1 }] }
  end
  let(:queue) { described_class.new(context) }

  it 'does not create a queue for an ordinary single request' do
    expect { queue.create([{ title: 'One question', assistant_id: entry.id }]) }.to raise_error(ArgumentError, /multiple/)
    expect(queue.tasks).to be_empty
  end

  it 'persists request IDs, marks completed once and hands the remaining request to its assigned actor' do
    queue.create([{ title: 'Book', assistant_id: entry.id }, { title: 'Delivery', assistant_id: entry.id + 1 }])
    first_id, second_id = queue.tasks.pluck('id')
    queue.update(id: first_id, status: 'completed', result: 'Confirmed appointment 17')
    expect { queue.update(id: first_id, status: 'active') }.to raise_error(ArgumentError, /Finished/)
    context[:state][:assistant_id] += 1
    queue.on_handoff
    expect(queue.active['id']).to eq(second_id)
    expect(session.read['tasks'].pluck('id')).to eq([first_id, second_id])
    expect(session.read['tasks'].first['result']).to eq('Confirmed appointment 17')
  end

  it 'does not discard unfinished tasks by starting another queue' do
    queue.create([{ title: 'Book', assistant_id: entry.id }, { title: 'Delivery', assistant_id: entry.id + 1 }])
    expect { queue.create([{ title: 'Repeat', assistant_id: entry.id }] * 2) }.to raise_error(ArgumentError, /already exists/)
  end

  it 'rejects task completion by a different actor or for an unknown agent' do
    expect { queue.create([{ title: 'Unknown', assistant_id: 0 }] * 2) }.to raise_error(ArgumentError, /unavailable/)
    queue.create([{ title: 'Book', assistant_id: entry.id }, { title: 'Delivery', assistant_id: entry.id + 1 }])
    expect { queue.update(id: queue.tasks.last['id'], status: 'completed') }.to raise_error(ArgumentError, /assigned/)
  end

  it 'allows two independent appointments to have separate action scopes' do
    queue.create([{ title: 'First appointment', assistant_id: entry.id }, { title: 'Second appointment', assistant_id: entry.id }])
    first = queue.operation_scope
    queue.update(id: queue.active['id'], status: 'completed')
    expect(queue.operation_scope).not_to eq(first)
  end

  it 'provides a valid nested tool schema' do
    schema = Captain::Runtime::TaskQueueTool.new.params_schema.deep_stringify_keys
    expect(JSONSchemer.schema(schema).valid?({ 'action' => 'create', 'tasks' => [{ 'title' => 'Book', 'assistant_id' => 1 }] })).to be(true)
    expect(JSONSchemer.schema(schema).valid?({ 'action' => 'create', 'tasks' => [{ 'title' => 'Book' }] })).to be(false)
  end

  it 'cannot invent new task identities for the same request after an action already started' do
    session.reserve_operation(scope: queue.request_scope, tool: 'create_appointment', arguments: {}, actor_id: entry.id)
    expect do
      queue.create([{ title: 'Book one', assistant_id: entry.id }, { title: 'Book two', assistant_id: entry.id }])
    end.to raise_error(ArgumentError, /before taking actions/)
    expect(session.read['tasks']).to be_empty
  end

  it 'lets the current agent cancel an obsolete request assigned to another agent' do
    queue.create([{ title: 'Book', assistant_id: entry.id }, { title: 'Delivery', assistant_id: entry.id + 1 }])
    task_id = queue.tasks.last['id']
    queue.update(id: task_id, status: 'cancelled', result: 'Customer withdrew the request')
    expect(session.read['tasks'].last).to include('id' => task_id, 'status' => 'cancelled')
    expect { queue.update(id: task_id, status: 'active') }.to raise_error(ArgumentError, /Finished/)
  end

  it 'rejects a second queue built from a stale snapshot of the same conversation' do
    conversation = create(:conversation, account: entry.account)
    first_session = Captain::Conversation::AgentSession.new(entry: entry, conversation: conversation)
    second_session = Captain::Conversation::AgentSession.new(entry: entry, conversation: conversation)
    first_session.read
    second_session.read
    first_context = context.merge(agent_session: first_session)
    second_context = context.deep_dup.merge(agent_session: second_session)
    items = [{ title: 'Book one', assistant_id: entry.id }, { title: 'Book two', assistant_id: entry.id }]
    first_queue = described_class.new(first_context)
    first_queue.create(items)
    ids = first_queue.tasks.pluck('id')
    expect { described_class.new(second_context).create(items) }.to raise_error(Captain::Conversation::ControlGenerationStaleError)
    expect(first_session.read['tasks'].pluck('id')).to eq(ids)
    stale_scope = 'task:stale-unpersisted-task'
    expect do
      second_session.reserve_operation(scope: stale_scope, tool: 'create_appointment', arguments: {}, actor_id: entry.id)
    end.to raise_error(Captain::Conversation::ControlGenerationStaleError)
    expect do
      second_session.reserve_operation(scope: 'request:request-1', tool: 'create_appointment', arguments: {}, actor_id: entry.id)
    end.to raise_error(Captain::Conversation::ControlGenerationStaleError)
  end

  context 'when persisting a change to a durable queue fails' do
    let(:conversation) { create(:conversation, account: entry.account) }
    let(:session) { Captain::Conversation::AgentSession.new(entry: entry, conversation: conversation) }
    let(:specialist) { create(:captain_assistant, account: entry.account) }
    let(:context) { super().merge(agent_graph: [{ id: entry.id }, { id: specialist.id }]) }

    def snapshot_queue(actor_id: entry.id)
      snapshot_session = Captain::Conversation::AgentSession.new(entry: entry, conversation: conversation)
      snapshot = snapshot_session.read
      snapshot_context = context.deep_dup.merge(agent_session: snapshot_session, agent_tasks: snapshot['tasks'])
      snapshot_context[:state].merge!(
        assistant_id: actor_id, entry_assistant_id: entry.id, agent_routing_revision: snapshot['routing_revision'],
        captain_response_fence: { entry_assistant_id: entry.id, routing_revision: snapshot['routing_revision'] }
      )
      [described_class.new(snapshot_context), snapshot_context, snapshot_session]
    end

    it 'restores task results, activation and action scope when completing a stale queue snapshot' do
      queue.create([{ title: 'Book one', assistant_id: entry.id }, { title: 'Book two', assistant_id: entry.id }])
      receipt_scope = queue.operation_scope
      _, receipt_key = session.reserve_operation(scope: receipt_scope, tool: 'get_appointment', arguments: { id: 17 }, actor_id: entry.id)
      session.finish_operation(receipt_key, { success: true, appointment_id: 17 })
      winning_queue, = snapshot_queue
      stale_queue, stale_context, stale_session = snapshot_queue
      before_tasks = stale_queue.tasks.deep_dup
      before_state = stale_context[:state].deep_dup
      winning_queue.update(id: before_tasks.first['id'], status: 'waiting', result: 'Waiting for customer confirmation')
      durable_after_winner = session.read

      expect do
        stale_queue.update(id: before_tasks.first['id'], status: 'completed', result: 'Appointment confirmed')
      end.to raise_error(Captain::Conversation::ControlGenerationStaleError)

      expect(stale_queue.tasks).to eq(before_tasks)
      expect(stale_context[:state]).to eq(before_state)
      expect(stale_queue.operation_scope).to eq(receipt_scope)
      expect do
        stale_session.reserve_operation(scope: stale_queue.operation_scope, tool: 'update_appointment', arguments: { id: 17 }, actor_id: entry.id)
      end.to raise_error(Captain::Conversation::ControlGenerationStaleError)
      expect(session.read).to eq(durable_after_winner)
      expect(session.read['operations'][receipt_key]).to include(
        'status' => 'finished', 'result' => { 'success' => true, 'appointment_id' => 17 }
      )
    end

    it 'restores the previous task owners and statuses when a stale handoff cannot activate its destination' do
      queue.create([{ title: 'Book', assistant_id: entry.id }, { title: 'Delivery', assistant_id: specialist.id }])
      winning_queue, = snapshot_queue
      stale_queue, stale_context, = snapshot_queue(actor_id: specialist.id)
      before_tasks = stale_queue.tasks.deep_dup
      before_state = stale_context[:state].deep_dup
      before_scope = stale_queue.operation_scope
      winning_queue.update(id: before_tasks.first['id'], status: 'waiting', result: 'Waiting for customer confirmation')
      durable_after_winner = session.read

      expect { stale_queue.on_handoff }.to raise_error(Captain::Conversation::ControlGenerationStaleError)

      expect(stale_queue.tasks).to eq(before_tasks)
      expect(stale_queue.active['assistant_id']).to eq(entry.id)
      expect(stale_context[:state]).to eq(before_state)
      expect(stale_queue.operation_scope).to eq(before_scope)
      expect(session.read).to eq(durable_after_winner)
      expect(session.read['current_assistant_id']).to eq(entry.id)
    end

    it 'restores the local queue and fence when persistence raises a database error' do
      queue.create([{ title: 'Book one', assistant_id: entry.id }, { title: 'Book two', assistant_id: entry.id }])
      context[:state][:entry_assistant_id] = entry.id
      context[:state][:captain_response_fence] = { entry_assistant_id: entry.id, routing_revision: context[:state][:agent_routing_revision] }
      before_tasks = queue.tasks.deep_dup
      before_state = context[:state].deep_dup
      before_session = session.read
      allow(session).to receive(:update_routing).and_raise(ActiveRecord::StatementInvalid, 'simulated database write failure')

      expect do
        queue.update(id: before_tasks.first['id'], status: 'completed', result: 'Appointment confirmed')
      end.to raise_error(ActiveRecord::StatementInvalid)

      expect(queue.tasks).to eq(before_tasks)
      expect(queue.tasks.pluck('status')).to eq(%w[active awaiting])
      expect(context[:state]).to eq(before_state)
      expect(session.read).to eq(before_session)
    end
  end
end
