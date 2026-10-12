require 'rails_helper'

RSpec.describe Captain::Runtime::PartRegistry do
  let(:context) do
    { state: { assistant_id: 1 }, agent_graph: [{ id: 1 }, { id: 2 }],
      agent_request_id: 'synthetic-request', parts: [] }
  end

  def plan(parts, mode: 'answer_myself', clarification: nil)
    described_class.new(context).accept!(mode: mode, parts: parts, clarification: clarification)
  end

  def next_message
    context.delete(:part_plan_accepted)
    context.delete(:part_plan)
  end

  describe '.planning_available?' do
    it 'is available only when the channel holds an agent other than the current one' do
      expect(described_class.planning_available?(context)).to be(true)
      expect(described_class.planning_available?(context.merge(state: { assistant_id: 2 }))).to be(true)
      expect(described_class.planning_available?(context.merge(agent_graph: [{ id: 1 }]))).to be(false)
      expect(described_class.planning_available?(context.merge(agent_graph: []))).to be(false)
      expect(described_class.planning_available?(context.except(:agent_graph))).to be(false)
    end
  end

  describe '.awaiting_confirmation?' do
    let(:proposal) { { 'id' => 'p', 'state' => 'waiting_confirmation', 'proposed_operation' => { 'type' => 'create_appointment' } } }

    it 'is true only while a stored part waits for confirmation with a proposed operation' do
      expect(described_class.awaiting_confirmation?(parts: [proposal])).to be(true)
      expect(described_class.awaiting_confirmation?(parts: [proposal.merge('state' => 'done')])).to be(false)
      expect(described_class.awaiting_confirmation?(parts: [proposal.merge('proposed_operation' => nil)])).to be(false)
      expect(described_class.awaiting_confirmation?(parts: [])).to be(false)
      expect(described_class.awaiting_confirmation?({})).to be(false)
    end
  end

  it 'validates the channel and allows at most three council parts' do
    invalid = [{ fragment: 'One', executor_agent_id: 3 }]
    expect { plan(invalid) }.to raise_error(ArgumentError, /unavailable/)
    four = Array.new(4) { |index| { fragment: "Part #{index}", executor_agent_id: index.even? ? 1 : 2 } }
    expect { plan(four, mode: 'council') }.to raise_error(ArgumentError, /one to three/)
  end

  it 'accepts a verified answer with one simple part in the plan call' do
    accepted = described_class.new(context).accept!(
      mode: 'answer_myself', parts: [{ fragment: 'Режим работы', executor_agent_id: 1 }],
      answer: 'Сегодня до 18:00.'
    )

    expect(accepted[:answer]).to eq('Сегодня до 18:00.')
    expect(accepted[:parts].sole['executor_agent_id']).to eq(1)
  end

  it 'links an answer to one open part and also creates a separately declared new part' do
    old = plan([{ fragment: 'Visit', executor_agent_id: 1 }])[:parts].sole
    next_message
    current = plan([
      { fragment: 'Tomorrow', executor_agent_id: 1, link_part_id: old['id'], link_action: 'answer' },
      { fragment: 'Price', executor_agent_id: 1, link_action: 'new' }
    ])[:parts]

    expect(current.first).to include('id' => old['id'], 'version' => 2)
    expect(current.last['id']).not_to eq(old['id'])
    expect(context[:parts].size).to eq(2)
  end

  it 'requires an explicit new request when an older part remains open' do
    plan([{ fragment: 'Visit', executor_agent_id: 1 }])
    next_message

    expect { plan([{ fragment: 'Tomorrow', executor_agent_id: 1 }]) }.to raise_error(ArgumentError, /link an open part/)
    expect(plan([{ fragment: 'Tomorrow', executor_agent_id: 1 }], mode: 'clarify',
                clarification: 'К какому запросу относится ответ?')[:mode]).to eq('clarify')
  end

  it 'preserves an exact proposal only when the customer confirms its part' do
    old = plan([{ fragment: 'Book', executor_agent_id: 1 }])[:parts].sole
    described_class.new(context).update!(old['id'], state: 'waiting_confirmation',
                                                    proposed_operation: { 'type' => 'create_appointment', 'params' => { 'slot_id' => 9 } })
    next_message
    confirmed = plan([{ fragment: 'Да', executor_agent_id: 1, link_part_id: old['id'],
                        link_action: 'confirmation' }])[:parts].sole

    expect(confirmed['proposed_operation']).to eq('type' => 'create_appointment', 'params' => { 'slot_id' => 9 })
    expect(confirmed['version']).to eq(2)
  end

  it 'keeps the recorded executor when confirming a proposed operation' do
    old = plan([{ fragment: 'Book', executor_agent_id: 1 }])[:parts].sole
    described_class.new(context).update!(old['id'], state: 'waiting_confirmation',
                                                    proposed_operation: { 'type' => 'create_appointment', 'params' => { 'slot_id' => 9 } })
    next_message

    expect do
      plan([{ fragment: 'Yes', executor_agent_id: 2, link_part_id: old['id'], link_action: 'confirmation' }], mode: 'council')
    end.to raise_error(ArgumentError, /executor agent/)
  end

  it 'links a new dependent part to the part planned right before it and keeps that link when confirming' do
    first, second = plan([{ fragment: 'Отменить визит', executor_agent_id: 1 },
                          { fragment: 'Записать на другое время', executor_agent_id: 1, relation: 'depends_on' }])[:parts]
    registry = described_class.new(context)
    registry.update!(first['id'], state: 'waiting_confirmation',
                                  proposed_operation: { 'type' => 'cancel_appointment', 'params' => { 'id' => 1 } })
    registry.update!(second['id'], state: 'waiting_confirmation',
                                   proposed_operation: { 'type' => 'create_appointment', 'params' => { 'slot_id' => 9 } })
    next_message
    confirmed = plan([{ fragment: 'Да', executor_agent_id: 1, link_part_id: second['id'], link_action: 'confirmation' },
                      { fragment: 'Да', executor_agent_id: 1, link_part_id: first['id'], link_action: 'confirmation' }])[:parts]

    expect(first).not_to have_key('depends_on_part_id')
    expect(second['depends_on_part_id']).to eq(first['id'])
    expect(confirmed.first).to include('id' => second['id'], 'version' => 2, 'depends_on_part_id' => first['id'])
    expect(described_class.executable_relation?(confirmed.first)).to be(true)
  end

  it 'does not run a dependent part that has no prerequisite or a conditional part' do
    lone = plan([{ fragment: 'Записать после отмены', executor_agent_id: 1, relation: 'depends_on' }])[:parts].sole

    expect(lone).not_to have_key('depends_on_part_id')
    expect(described_class.executable_relation?(lone)).to be(false)
    expect(described_class.executable_relation?(lone.merge('relation' => 'conditional'))).to be(false)
    expect(described_class.executable_relation?(lone.merge('relation' => 'independent'))).to be(true)
  end

  it 'cannot confirm an operation again after its outcome became unknown' do
    old = plan([{ fragment: 'Book', executor_agent_id: 1 }])[:parts].sole
    registry = described_class.new(context)
    registry.update!(old['id'], state: 'waiting_confirmation',
                                proposed_operation: { 'type' => 'create_appointment', 'params' => { 'slot_id' => 9 } })
    registry.record_outcome!(old['id'], 'unknown')
    next_message

    expect do
      plan([{ fragment: 'Да', executor_agent_id: 1, link_part_id: old['id'], link_action: 'confirmation' }])
    end.to raise_error(ArgumentError, /no operation awaiting confirmation/)
    expect(context[:parts].sole['state']).to eq('unknown')
  end

  it 'persists a part across messages and an agent ownership change' do
    entry = create(:captain_assistant)
    specialist = create(:captain_assistant, account: entry.account)
    conversation = create(:conversation, account: entry.account)
    session = Captain::Conversation::AgentSession.new(entry: entry, conversation: conversation)
    first_context = { state: { assistant_id: entry.id }, agent_graph: [{ id: entry.id }, { id: specialist.id }],
                      agent_session: session, agent_request_id: 'first', parts: [] }
    first = described_class.new(first_context).accept!(
      mode: 'answer_myself', parts: [{ fragment: 'Запись', executor_agent_id: entry.id }]
    )[:parts].sole
    session.update_routing(actor_id: specialist.id)
    next_context = { state: { assistant_id: specialist.id }, agent_graph: first_context[:agent_graph],
                     agent_session: session, agent_request_id: 'second', parts: session.read['parts'] }
    linked = described_class.new(next_context).accept!(
      mode: 'answer_myself', parts: [{ fragment: 'Ответ', executor_agent_id: specialist.id,
                                      link_part_id: first['id'], link_action: 'answer' }]
    )[:parts].sole

    expect(linked).to include('id' => first['id'], 'version' => 2, 'executor_agent_id' => specialist.id)
    expect(session.read['parts'].sole['version']).to eq(2)
  end

  it 'keeps a completed operation receipt for its part' do
    entry = create(:captain_assistant)
    session = Captain::Conversation::AgentSession.new(entry: entry)
    session.change do |data|
      data['parts'] = [{ 'id' => 'synthetic-part', 'version' => 1,
                         'executor_agent_id' => entry.id, 'state' => 'open' }]
    end
    scope = 'part:synthetic-part:v1'
    first_status, key = session.reserve_operation(scope: scope, tool: 'create_appointment',
                                                  arguments: { slot_id: 9 }, actor_id: entry.id)
    session.finish_operation(key, Captain::ToolResult.success(data: { appointment_id: 77 }))
    second_status, receipt = session.reserve_operation(scope: scope, tool: 'create_appointment',
                                                       arguments: { slot_id: 9 }, actor_id: entry.id)

    expect(first_status).to eq(:reserved)
    expect(second_status).to eq(:existing)
    expect(receipt['status']).to eq('finished')
  end

  it 'leaves the mode out of a plan that only confirms stored proposals, but not out of a mixed plan' do
    old = plan([{ fragment: 'Book', executor_agent_id: 2 }, { fragment: 'Price', executor_agent_id: 1 }], mode: 'council')[:parts].first
    confirm = [{ fragment: 'Да', executor_agent_id: 2, link_part_id: old['id'], link_action: 'confirmation' }]

    %w[answer_myself council].each_with_index do |mode, index|
      described_class.new(context).update!(old['id'], state: 'waiting_confirmation',
                                                      proposed_operation: { 'type' => 'create_appointment', 'params' => { 'slot_id' => 9 } })
      next_message
      context[:agent_request_id] = "confirm-#{index}"

      expect(plan(confirm, mode: mode)[:parts].sole).to include('id' => old['id'], 'executor_agent_id' => 2, 'link_action' => 'confirmation')
    end

    described_class.new(context).update!(old['id'], state: 'waiting_confirmation',
                                                    proposed_operation: { 'type' => 'create_appointment', 'params' => { 'slot_id' => 9 } })
    next_message
    context[:agent_request_id] = 'mixed'
    mixed = confirm + [{ fragment: 'Ещё', executor_agent_id: 2, link_action: 'new' }]
    expect { plan(mixed, mode: 'answer_myself') }.to raise_error(ArgumentError, 'This part belongs to another agent')
  end

  it 'has no handoff mode: a transfer to one colleague is that colleague\'s own tool, not a plan' do
    expect(described_class::MODES).to eq(%w[answer_myself council clarify])
    expect { plan([{ fragment: 'Book', executor_agent_id: 2 }], mode: 'handoff') }.to raise_error(ArgumentError, 'Invalid request mode')
  end

  it 'turns the parts through the given block only for a new plan and replays a saved plan as it was' do
    entry = create(:captain_assistant)
    session = Captain::Conversation::AgentSession.new(entry: entry)
    registry_context = { state: { assistant_id: entry.id }, agent_graph: [{ id: entry.id }], agent_session: session,
                         agent_request_id: 'once', parts: [] }
    turned = []
    block = lambda do |items|
      turned << items
      items.map { |item| item.merge(executor_agent_id: entry.id) }
    end

    first = described_class.new(registry_context).accept!(mode: 'answer_myself', parts: [{ fragment: 'Адрес' }], &block)
    replay_context = registry_context.merge(parts: session.read['parts'])
    replay_context.delete(:part_plan_accepted)
    replayed = described_class.new(replay_context).accept!(mode: 'answer_myself', parts: [{ fragment: 'Другое' }], &block)

    expect(first[:parts].sole).to include('executor_agent_id' => entry.id, 'fragment' => 'Адрес')
    expect(replayed[:parts].sole['fragment']).to eq('Адрес')
    expect(turned).to eq([[{ fragment: 'Адрес' }]])
  end

  it 'treats a plain confirmation without a stored proposal as an answer to the open part' do
    old = plan([{ fragment: 'Запишите к терапевту', executor_agent_id: 1 }])[:parts].sole
    next_message

    part = plan([{ fragment: 'Да', executor_agent_id: 1, link_part_id: old['id'], link_action: 'confirmation' }])[:parts].sole

    expect(part).to include('id' => old['id'], 'version' => 2, 'link_action' => 'answer')
    expect(part['proposed_operation']).to be_nil
  end
end
