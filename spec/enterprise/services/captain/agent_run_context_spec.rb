require 'rails_helper'

RSpec.describe Captain::AgentRunContext do
  let(:account) { create(:account) }
  let(:entry) { create(:captain_assistant, account: account, description: 'ENTRY PRIVATE PROMPT') }
  # The mesh reads channel members from the database, so the specialist must exist before the graph is built.
  let!(:specialist) do
    create(:captain_assistant, account: account, description: 'SPECIALIST OWN PROMPT', routing_description: 'Запись на приём')
  end
  let(:conversation) { create(:conversation, account: account) }
  let(:context) { { state: { account_id: account.id, assistant_id: entry.id }, conversation_history: [] } }

  after { Current.executed_by = nil }

  it 'does not repeat input checks when an agent is activated' do
    expect(Captain::Safety::CustomRulesRuntime).not_to receive(:check_input!)

    runtime = described_class.new(entry: entry)
    runtime.prepare(context)
    runtime.activate(specialist, context)
    runtime.activate(entry, context)
  end

  it 'builds direct routes in both directions and preserves each agent own prompt' do
    runtime = described_class.new(entry: entry)
    agents = runtime.runtime_agents
    expect(agents.map(&:name)).to contain_exactly("assistant_#{entry.id}", "assistant_#{specialist.id}")
    expect(agents.first.handoff_agents.map(&:assistant_id)).to eq([specialist.id])
    expect(agents.last.handoff_agents.map(&:assistant_id)).to eq([entry.id])
    description = Captain::Runtime::HandoffTool.new(agents.last).description
    expect(description).to start_with("Transfer the conversation to #{specialist.name}.")
    expect(description).to include(specialist.name, specialist.routing_description.to_s)
    expect(description).not_to include("assistant_#{specialist.id}")
    runtime.prepare(context)
    runtime.activate(specialist, context)
    prompt = specialist.agent_instructions(Captain::Runtime::RunContext.new(context))
    expect(prompt).to include('SPECIALIST OWN PROMPT')
    expect(prompt).not_to include('ENTRY PRIVATE PROMPT')
  end

  it 'materializes only the acting agent when building the runtime' do
    runtime = described_class.new(entry: entry, conversation: conversation)
    agents = runtime.runtime_agents
    expect(agents).to all(be_a(Captain::Runtime::LazyAgent))
    expect(agents.any? { |agent| agent.instance_variable_defined?(:@materialized) }).to be(false)
    agents.first.tools
    expect(agents.first.instance_variable_defined?(:@materialized)).to be(true)
    expect(agents.last.instance_variable_defined?(:@materialized)).to be(false)
  end

  it 'continues with the last actor on the next message in the same physical conversation' do
    first = described_class.new(entry: entry, conversation: conversation)
    first.prepare(context)
    first.activate(specialist, context)
    next_context = { state: { account_id: account.id, assistant_id: entry.id } }
    described_class.new(entry: entry, conversation: conversation.reload).prepare(next_context)
    expect(next_context[:acting_assistant_id]).to eq(specialist.id)
    sibling = create(:conversation, account: account, contact: conversation.contact)
    sibling_context = { state: { account_id: account.id, assistant_id: entry.id } }
    described_class.new(entry: entry, conversation: sibling).prepare(sibling_context)
    expect(sibling_context[:acting_assistant_id]).to eq(entry.id)
  end

  it 'retains public dialogue while removing peer tool payloads and private reasoning' do
    runtime = described_class.new(entry: entry)
    runtime.prepare(context)
    context[:conversation_history] = [
      { role: :user, content: 'Book for tomorrow' },
      { role: :assistant, content: '', tool_calls: [{ id: 'secret-tool' }] },
      { role: :tool, content: 'restricted source text', tool_call_id: 'secret-tool' },
      { role: :assistant, content: { response: 'What time?', reasoning: 'private' }.to_json, reasoning: 'private' }
    ]
    runtime.activate(specialist, context)
    expect(context[:conversation_history]).to eq([
      { role: :user, content: 'Book for tomorrow' }, { role: :assistant, content: 'What time?' }
    ])
  end

  it 'falls back to the entry if the previously active agent was disabled' do
    runtime = described_class.new(entry: entry, conversation: conversation)
    runtime.prepare(context)
    runtime.activate(specialist, context)
    specialist.update!(active: false)
    described_class.new(entry: entry.reload, conversation: conversation.reload).prepare(context)
    expect(context[:acting_assistant_id]).to eq(entry.id)
  end

  it 'restores the selected playground reasoning override on return without passing it to a specialist' do
    runtime = described_class.new(entry: entry)
    context[:state][:playground_thinking_effort] = 'none'
    runtime.prepare(context)
    expect(context[:state][:playground_thinking_effort]).to eq('none')

    runtime.activate(specialist, context)
    expect(context[:state]).not_to have_key(:playground_thinking_effort)

    runtime.activate(entry, context)
    expect(context[:state][:playground_thinking_effort]).to eq('none')
    expect(context[:state][:captain_runtime]['assistant_thinking_effort']).to eq('none')
  end

  it 'retains the standalone internal-agent path without granting external handoffs' do
    entry.update!(usage_mode: 'internal_assistant')
    expect(Captain::AgentGraph.new(entry).agents).to eq([entry])
  end
end
