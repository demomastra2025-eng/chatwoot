# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Runtime::CoordinationPrompt do
  let(:entry) { { id: 91, key: 'assistant_91', name: 'Orders', description: 'Order enquiries', target_ids: [92] } }
  let(:specialist) { { id: 92, key: 'assistant_92', name: 'Appointments', description: 'Appointment changes', target_ids: [91] } }
  let(:tasks) do
    [
      { 'id' => 'order', 'assistant_id' => 91, 'status' => 'waiting', 'title' => 'Prepare an order', 'result' => 'Amount needed' },
      { 'id' => 'visit', 'assistant_id' => 92, 'status' => 'active', 'title' => 'Move the appointment', 'result' => nil }
    ]
  end
  let(:context) { { state: { assistant_id: 91 }, agent_graph: [entry, specialist], agent_tasks: tasks } }

  def data_line(prompt, label)
    JSON.parse(prompt.lines.find { |line| line.start_with?("#{label} (data): ") }.delete_prefix("#{label} (data): "))
  end

  it 'renders the current actor and only their task assignments after a handoff, retaining the shared queue' do
    before = described_class.render(context)
    context[:state][:assistant_id] = 92
    after = described_class.render(context)

    expect(data_line(before, 'Current agent')).to eq(entry.deep_stringify_keys)
    expect(data_line(before, 'Your tasks')).to eq([tasks.first])
    expect(data_line(after, 'Current agent')).to eq(specialist.deep_stringify_keys)
    expect(data_line(after, 'Your tasks')).to eq([tasks.last])
    expect(data_line(after, 'Task queue')).to eq(tasks)
    expect(tasks.pluck('status')).to eq(%w[waiting active])
  end

  it 'does not guess an actor or expose a previous actor assignment when the current id is absent from the graph' do
    context[:state][:assistant_id] = 99

    prompt = described_class.render(context)

    expect(data_line(prompt, 'Current agent')).to be_nil
    expect(data_line(prompt, 'Your tasks')).to eq([])
  end

  it 'lists each other channel agent once for a new part-registry conversation' do
    context[:agent_tasks] = []

    prompt = described_class.render(context)

    expect(prompt.scan('Appointments: Appointment changes').size).to eq(1)
    expect(prompt).not_to include('target_ids', 'Agent directory (data)', 'manage_agent_tasks')
    expect(prompt).to include('plan_request')
  end

  it 'asks for a plan only for separate requests of different agents or an answer to an open part, never for a transfer' do
    context[:agent_tasks] = []

    prompt = described_class.render(context)
    text = prompt.squish

    expect(text).to include('Your own work needs no plan: answer directly, look facts up with read-only tools or the FAQ, ' \
                            'take your own actions that change data (book, reschedule, cancel, update a card) ' \
                            'and use the human handoff, all without plan_request.')
    expect(text).to include('Plan with plan_request only in these cases: when the message holds several separate requests that ' \
                            'belong to different agents (a council), or when the customer confirms, corrects, cancels or answers ' \
                            'a request listed in the open parts below')
    expect(text).to include('When you plan, link answers, corrections and cancellations to open parts.')
    expect(text).to include('reply directly without plan_request')
    expect(text).not_to include('before transferring the conversation', 'mode handoff', 'do not call a transfer tool')
    expect(prompt).not_to include('before an action that changes data', 'A simple request needs no plan',
                                  'Plan the customer\'s request before taking any action', 'Use plan_request once')
  end

  it 'sends a request of one colleague through that colleague\'s transfer tool, with no plan' do
    context[:agent_tasks] = []

    text = described_class.render(context).squish

    expect(text).to include('A request that belongs to one colleague is passed on with that colleague\'s transfer tool, ' \
                            'the tool whose description names the colleague: call it, no plan is needed.')
    expect(text).to include('The colleague sees the whole conversation and answers the customer, so write no reply of your own ' \
                            'before or after that call.')
    expect(text.index('transfer tool')).to be < text.index('Plan with plan_request only in these cases')
    expect(text).to include('Staff or an operator is reached only through the handoff tool, never through plan_request.')
  end

  it 'tells the agent not to carry out an operation that waits for confirmation itself, and keeps the human handoff rules' do
    context[:agent_tasks] = []

    prompt = described_class.render(context)

    expect(prompt.squish).to include('An operation waiting for confirmation is carried out or cancelled only through such a plan, ' \
                                     'so do not take that action yourself.')
    expect(prompt).to include(described_class::HUMAN_HANDOFF_RULES)
    expect(prompt.scan('call the handoff tool').size).to eq(1)
  end

  it 'keeps the answer shortcut of the plan and the council limit' do
    context[:agent_tasks] = []

    prompt = described_class.render(context)

    expect(prompt).to include('Set answer in that call only when the complete answer is verified from supplied context and needs no tool.')
    expect(prompt).to include('One request with several details (doctor, date, patient, price of the same service) is ONE part, never a council.')
  end

  it 'tells the agent its own name and asks to name an executor by the agent name, never by an id' do
    context[:agent_tasks] = []

    prompt = described_class.render(context)

    expect(prompt).to start_with('You are Orders, the current agent')
    expect(prompt).to include('Never mention internal routing or agent names.')
    expect(prompt).to include('In plan_request, name the executor of a part by the agent name exactly as listed above; omit it for your own parts.')
    expect(prompt).not_to include("that agent's ID", 'executor_agent_id', 'assistant_92')
  end

  it 'shows stored executors by name in the open parts and the accepted plan' do
    context[:agent_tasks] = []
    context[:parts] = [{ 'id' => 'open-part', 'state' => 'open', 'executor_agent_id' => 92, 'fragment' => 'Перенести' },
                       { 'id' => 'done-part', 'state' => 'done', 'executor_agent_id' => 91 }]

    open_parts = data_line(described_class.render(context), 'Open parts')
    expect(open_parts).to eq([{ 'id' => 'open-part', 'state' => 'open', 'fragment' => 'Перенести', 'executor' => 'Appointments' }])

    context[:part_plan_accepted] = true
    context[:part_plan] = { mode: 'handoff', parts: [{ 'id' => 'plan-part', 'version' => 1, 'executor_agent_id' => 92 }] }
    prompt = described_class.render(context)
    plan = JSON.parse(prompt[/Plan accepted \(data\): (.*?)\. Continue only/, 1])

    expect(plan['parts']).to eq([{ 'id' => 'plan-part', 'version' => 1, 'executor' => 'Appointments' }])
    expect(prompt).not_to include('executor_agent_id')
    expect(context[:parts].first).to include('executor_agent_id' => 92)
  end

  it 'says so when the agent is alone on the channel and does not invent a name for an unnamed agent' do
    context[:agent_tasks] = []
    context[:agent_graph] = [entry]

    expect(described_class.render(context)).to start_with('You are Orders, the current agent').and include(
      '(none: you are the only agent on this channel)'
    )

    context[:agent_graph] = [{ id: 91 }]
    expect(described_class.render(context)).to start_with('You are the current agent. Handle requests in your own responsibility.')
  end

  it 'does not ask a specialist to plan the same message after a plan stored with the former handoff mode' do
    context[:agent_tasks] = []
    context[:part_plan_accepted] = true
    context[:part_plan] = { mode: 'handoff', parts: [{ 'id' => 'synthetic-part', 'executor_agent_id' => 92 }] }
    context[:state][:assistant_id] = 92

    prompt = described_class.render(context)

    expect(prompt).to include('Plan accepted')
    expect(prompt).not_to include('No plan exists', 'call plan_request once')
  end

  it 'does not force the colleague that received a transfer without a plan to plan' do
    context[:agent_tasks] = []
    context[:state][:assistant_id] = 92

    text = described_class.render(context).squish

    expect(text).to start_with('You are Appointments, the current agent')
    expect(text).to include('Continue the same customer conversation after an internal transfer. Never mention internal routing or agent names.')
    expect(text).to include('No plan exists for this customer message yet. When none of the cases above applies, reply directly ' \
                            'without plan_request (or call a transfer tool).')
    expect(text).not_to include('Plan accepted', 'before replying', 'Call plan_request for this message')
  end
end
