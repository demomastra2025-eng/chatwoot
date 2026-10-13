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
    runtime = described_class.new(entry: entry, conversation: conversation)
    agents = runtime.runtime_agents
    expect(agents.map(&:name)).to contain_exactly("assistant_#{entry.id}", "assistant_#{specialist.id}")
    expect(agents.first.handoff_agents.map(&:assistant_id)).to eq([specialist.id])
    expect(agents.last.handoff_agents.map(&:assistant_id)).to eq([entry.id])
    transfer = Captain::Runtime::HandoffTool.new(agents.last)
    expect(transfer.name).to eq("transfer_to_agent_#{specialist.id}")
    expect(transfer.description).to eq(%(Transfer the conversation to colleague "#{specialist.name}": #{specialist.routing_description}))
    expect(transfer.description).not_to include("assistant_#{specialist.id}")
    runtime.prepare(context)
    runtime.activate(specialist, context)
    prompt = specialist.agent_instructions(Captain::Runtime::RunContext.new(context))
    expect(prompt).to include('SPECIALIST OWN PROMPT')
    expect(prompt).not_to include('ENTRY PRIVATE PROMPT')
  end

  it 'does not load the channel peers for the prompt of a mesh run, which drops the list anyway' do
    runtime = described_class.new(entry: entry, conversation: conversation)
    runtime.prepare(context)
    runtime.activate(specialist, context)
    expect(context[:state][:mesh_routing]).to be(true)
    expect(specialist).not_to receive(:channel_peers)

    prompt = specialist.agent_instructions(Captain::Runtime::RunContext.new(context))

    expect(prompt).to include('SPECIALIST OWN PROMPT')
  end

  it 'still lists the channel peers when the prompt is built outside a mesh run' do
    expect(entry).to receive(:channel_peers).and_call_original

    expect(entry.send(:runtime_prompt_context, { account_id: account.id })[:scenarios].pluck(:title)).to eq([specialist.name])
    expect(entry.send(:runtime_prompt_context, { mesh_routing: true })[:scenarios]).to eq([])
  end

  it 'gives a run without a channel a single agent with no routes' do
    runtime = described_class.new(entry: entry)
    agents = runtime.runtime_agents

    expect(agents.map(&:name)).to eq(["assistant_#{entry.id}"])
    expect(agents.first.handoff_agents).to be_empty
    runtime.prepare(context)
    expect(context[:agent_graph]).to eq([])
    expect(context[:state][:agent_graph_ids]).to eq([entry.id])
  end

  it 'gives a run the directory of its channel when other agents work there' do
    described_class.new(entry: entry, conversation: conversation).prepare(context)

    expect(context[:agent_graph].pluck(:id)).to contain_exactly(entry.id, specialist.id)
    expect(context[:state][:agent_graph_ids]).to contain_exactly(entry.id, specialist.id)
    expect(context[:state][:entry_assistant_id]).to eq(entry.id)
  end

  it 'gives the main agent that is alone on its channel no directory and drops a request queue left from other times' do
    specialist.update!(channel_scope: 'selected')
    stale = [{ 'id' => 'old', 'title' => 'Old request', 'assistant_id' => entry.id, 'status' => 'waiting', 'result' => nil }]
    Captain::Conversation::AgentSession.new(entry: entry, conversation: conversation).update_routing(actor_id: entry.id, tasks: stale)

    described_class.new(entry: entry, conversation: conversation).prepare(context)

    expect(context[:agent_graph]).to eq([])
    expect(context[:agent_tasks]).to eq([])
    expect(context[:state][:agent_graph_ids]).to eq([entry.id])
    expect(Captain::Conversation::AgentSession.new(entry: entry, conversation: conversation).read['tasks']).to eq([])
  end

  describe 'what the model is given for the run' do
    let(:lone_account) { create(:account) }
    let(:lone_entry) { create(:captain_assistant, account: lone_account, description: 'LONE PRIVATE PROMPT') }
    let(:lone_conversation) { create(:conversation, account: lone_account) }
    let(:lone_context) { { state: { account_id: lone_account.id, assistant_id: lone_entry.id }, conversation_history: [] } }

    def tool_names(runtime, run_context)
      Captain::Runtime::ChatFactory.send(:build_agent_tools, runtime.runtime_agents.first, run_context).map(&:name)
    end

    def prompt_of(runtime, run_context)
      Captain::Runtime::ChatFactory.send(:system_prompt_for, runtime.runtime_agents.first, run_context)
    end

    it 'gives an agent with peers the plan tool, the transfer tools and the coordination prompt' do
      runtime = described_class.new(entry: entry, conversation: conversation)
      runtime.prepare(context)
      run_context = Captain::Runtime::RunContext.new(context)

      expect(tool_names(runtime, run_context))
        .to include('plan_request', "transfer_to_agent_#{specialist.id}")
      expect(prompt_of(runtime, run_context)).to include(
        'ENTRY PRIVATE PROMPT', %(You are "#{entry.name}"), '# Colleagues on this channel', 'plan_request', 'a council'
      )
    end

    it 'gives a lone main agent neither a plan, a council nor a transfer: just its own prompt and tools' do
      runtime = described_class.new(entry: lone_entry, conversation: lone_conversation)
      runtime.prepare(lone_context)
      run_context = Captain::Runtime::RunContext.new(lone_context)

      names = tool_names(runtime, run_context)
      expect(names).not_to include('plan_request', 'manage_agent_tasks')
      expect(names.select { |name| name.start_with?(Captain::HandoffNaming::TOOL_PREFIX) }).to be_empty
      prompt = prompt_of(runtime, run_context)
      expect(prompt).to include('LONE PRIVATE PROMPT')
      expect(prompt).not_to match(/plan_request|council|manage_agent_tasks|Other agents|main agent|specialist of this channel/)
    end
  end

  it 'takes the peers from the channel of the conversation, not from a stored list of the entry agent' do
    entry.update!(handoff_agent_ids: [])
    outsider = create(:captain_assistant, account: account, channel_scope: 'selected')
    runtime = described_class.new(entry: entry, conversation: conversation)

    expect(runtime.runtime_agents.map(&:assistant_id)).to eq([entry.id, specialist.id])
    expect(runtime.graph.find(outsider.id)).to be_nil
    Captain::AgentChannel.create!(account: account, inbox: conversation.inbox, assistant: outsider)
    expect(described_class.new(entry: entry, conversation: conversation).graph.find(outsider.id)).to eq(outsider)
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
