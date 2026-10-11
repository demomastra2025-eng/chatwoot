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
end
