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

  it 'asks for a plan only before an action, a transfer, several separate requests or an answer to an open part' do
    context[:agent_tasks] = []

    prompt = described_class.render(context)

    expect(prompt).to include('A simple request needs no plan')
    expect(prompt).to include('Plan with plan_request only in these cases: before an action that changes data, ' \
                              "before transferring to another agent,\nwhen the message holds several separate requests, " \
                              "or when the customer confirms, corrects, cancels or answers a request\nlisted in the open parts")
    expect(prompt).to include('When you plan, link answers, corrections and cancellations to open parts.')
    expect(prompt).to include('reply directly without plan_request')
    expect(prompt).not_to include('Plan the customer\'s request before taking any action', 'Use plan_request once')
  end

  it 'keeps the answer shortcut of the plan and the council limit' do
    context[:agent_tasks] = []

    prompt = described_class.render(context)

    expect(prompt).to include('Set answer in that call only when the complete answer is verified from supplied context and needs no tool.')
    expect(prompt).to include('One request with several details (doctor, date, patient, price of the same service) is ONE part, never a council.')
  end

  it 'does not ask a specialist to plan the same message after a handoff' do
    context[:agent_tasks] = []
    context[:part_plan_accepted] = true
    context[:part_plan] = { mode: 'handoff', parts: [{ 'id' => 'synthetic-part', 'executor_agent_id' => 92 }] }
    context[:state][:assistant_id] = 92

    prompt = described_class.render(context)

    expect(prompt).to include('Plan accepted')
    expect(prompt).not_to include('No plan exists', 'call plan_request once')
  end
end
