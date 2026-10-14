require 'rails_helper'

RSpec.describe Captain::AgentRunContext do
  let(:account) { create(:account) }
  let(:entry) do
    create(:captain_assistant, account: account, description: 'ENTRY PRIVATE PROMPT',
                               config: { 'tool_access' => { 'agent' => { 'enabled' => true, 'tool_ids' => ['handoff'] } } })
  end
  # The mesh reads channel members from the database, so the specialist must exist before the graph is built.
  let!(:specialist) do
    create(:captain_assistant, account: account, description: 'SPECIALIST OWN PROMPT', routing_description: 'Запись на приём',
                               config: { 'tool_access' => { 'agent' => { 'enabled' => true, 'tool_ids' => %w[create_appointment handoff] } } })
  end
  let(:conversation) { create(:conversation, account: account) }
  let(:context) { { state: { account_id: account.id, assistant_id: entry.id }, conversation_history: [] } }

  after { Current.executed_by = nil }
  before { account.enable_features!('scheduling') }

  it 'does not repeat input checks when an agent is activated' do
    expect(Captain::Safety::CustomRulesRuntime).not_to receive(:check_input!)

    runtime = described_class.new(entry: entry)
    runtime.prepare(context)
    runtime.activate(specialist, context)
    runtime.activate(entry, context)
  end

  it 'builds a route to the missing booking action' do
    runtime = described_class.new(entry: entry, conversation: conversation)
    agents = runtime.runtime_agents
    expect(agents.map(&:name)).to contain_exactly("assistant_#{entry.id}", "assistant_#{specialist.id}")
    expect(agents.first.handoff_agents.map(&:assistant_id)).to eq([specialist.id])
    expect(agents.last.handoff_agents).to be_empty
    transfer = Captain::Runtime::HandoffTool.new(agents.last, source_agent: agents.first)
    expect(transfer.name).to eq("transfer_to_agent_#{specialist.id}")
    expect(transfer.description).to start_with(%(Transfer the conversation to colleague "#{specialist.name}": book appointments. Note:))
    expect(transfer.description).to end_with(Captain::Runtime::HandoffTool::WHEN_TO_USE)
    expect(transfer.description).not_to include("assistant_#{specialist.id}")
  end

  it 'preserves the specialist own prompt' do
    runtime = described_class.new(entry: entry, conversation: conversation)
    runtime.prepare(context)
    runtime.activate(specialist, context)
    prompt = specialist.agent_instructions(Captain::Runtime::RunContext.new(context))
    expect(prompt).to include('SPECIALIST OWN PROMPT')
    expect(prompt).not_to include('ENTRY PRIVATE PROMPT')
  end

  it 'does not load the channel peers for the agent prompt: the coordination prompt describes them' do
    runtime = described_class.new(entry: entry, conversation: conversation)
    runtime.prepare(context)
    runtime.activate(specialist, context)
    expect(context[:state][:mesh_routing]).to be(true)
    expect(specialist).not_to receive(:channel_peers)
    expect(entry).not_to receive(:channel_peers)

    prompt = specialist.agent_instructions(Captain::Runtime::RunContext.new(context))

    expect(prompt).to include('SPECIALIST OWN PROMPT')
    expect(entry.agent_instructions).not_to include(specialist.name)
    expect(entry.send(:runtime_prompt_context, { account_id: account.id })).not_to have_key(:scenarios)
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
    specialist.update!(active: false)
    stale = [{ 'id' => 'old', 'title' => 'Old request', 'assistant_id' => entry.id, 'status' => 'waiting', 'result' => nil }]
    Captain::Conversation::AgentSession.new(entry: entry, conversation: conversation).update_routing(actor_id: entry.id, tasks: stale)

    described_class.new(entry: entry, conversation: conversation).prepare(context)

    expect(context[:agent_graph]).to eq([])
    expect(context[:agent_tasks]).to eq([])
    expect(context[:state][:agent_graph_ids]).to eq([entry.id])
    expect(Captain::Conversation::AgentSession.new(entry: entry, conversation: conversation).read['tasks']).to eq([])
  end

  describe 'what the agents already did in the conversation' do
    let(:booked) do
      { 'tool' => 'create_appointment', 'label' => 'Booked', 'text' => 'Терапевт Нурланова Асель, Fri 16.10.2026 09:00',
        'request' => 'request:earlier' }
    end

    before do
      Captain::Conversation::AgentSession.new(entry: entry, conversation: conversation).change { |data| data['done'] = [booked] }
      context[:agent_request_id] = 'run-1'
    end

    it 'gives the run the list that the session kept' do
      described_class.new(entry: entry, conversation: conversation).prepare(context)

      expect(context[:done_actions]).to eq([booked])
    end

    it 'gives a run of a new conversation an empty list' do
      described_class.new(entry: entry, conversation: create(:conversation, account: account)).prepare(context)

      expect(context[:done_actions]).to eq([])
    end

    it 'shows the agent that takes the turn after a transfer what was done earlier and what was done in reply to this message' do
      runtime = described_class.new(entry: entry, conversation: conversation)
      runtime.prepare(context)
      runtime.activate(specialist, context)
      moved = { 'tool' => 'update_appointment', 'label' => 'Rescheduled', 'text' => 'Терапевт Нурланова Асель, now Thu 15.10.2026 11:00',
                'request' => 'request:run-1' }
      context[:done_actions] = Captain::DoneActions.remember(context[:done_actions], moved)

      prompt = specialist.agent_instructions(Captain::Runtime::RunContext.new(context))

      expect(prompt).to include(
        "Done in this conversation:\n" \
        "- Rescheduled: Терапевт Нурланова Асель, now Thu 15.10.2026 11:00 (in reply to this message)\n" \
        '- Booked: Терапевт Нурланова Асель, Fri 16.10.2026 09:00 (earlier)'
      )
    end

    it 'leaves the list out of the prompt of a conversation where nothing was done' do
      runtime = described_class.new(entry: entry, conversation: create(:conversation, account: account))
      runtime.prepare(context)
      runtime.activate(specialist, context)

      expect(specialist.agent_instructions(Captain::Runtime::RunContext.new(context))).not_to include('Done in this conversation')
    end
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
        'ENTRY PRIVATE PROMPT', %(You are "#{entry.name}"), '# Colleagues on this channel', 'call plan_request once to split it'
      )
    end

    it 'gives every agent the FAQ and the service catalog as read tools, and does not present them as a reason to transfer' do
      account.enable_features!('scheduling')
      entry.update!(config: { 'tool_access' => { 'agent' => { 'enabled' => true, 'tool_ids' => ['handoff'] } } })
      specialist.update!(config: { 'tool_access' => { 'agent' => { 'enabled' => true, 'tool_ids' => %w[create_appointment handoff] } } })
      runtime = described_class.new(entry: entry, conversation: conversation)
      runtime.prepare(context)
      run_context = Captain::Runtime::RunContext.new(context)

      names = tool_names(runtime, run_context)

      expect(names).to include('faq_lookup', 'search_scheduling_services', 'handoff', "transfer_to_agent_#{specialist.id}")
      expect(names).to eq(names.uniq)
      expect(names).not_to include('create_appointment')
      Captain::Runtime::ChatFactory.send(:record_bound_agent_tools, runtime.runtime_agents.first, run_context)
      expect(run_context.context[:captain_v2_bound_tool_ids]).to include('faq_lookup', 'search_scheduling_services')
      transfer = Captain::Runtime::HandoffTool.new(runtime.runtime_agents.last)
      expect(transfer.description).to include('book appointments')
      expect(transfer.description).not_to include('service prices')
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

  it 'takes every active text-channel peer regardless of stored handoff lists or legacy channel links' do
    entry.update!(handoff_agent_ids: [])
    outsider = create(:captain_assistant, account: account, channel_scope: 'selected')
    runtime = described_class.new(entry: entry, conversation: conversation)

    expect(runtime.runtime_agents.map(&:assistant_id)).to eq([entry.id, specialist.id, outsider.id])
    expect(runtime.graph.find(outsider.id)).to eq(outsider)
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
