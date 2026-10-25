require 'rails_helper'

RSpec.describe Captain::AgentRunContext do
  let(:account) { create(:account) }
  let(:entry) do
    create(:captain_assistant, account: account, description: 'ENTRY PRIVATE PROMPT', routing_description: 'Общие вопросы о клинике',
                               config: { 'tool_access' => { 'agent' => { 'enabled' => true, 'tool_ids' => ['handoff'] } } })
  end
  # The channel members are read from the database, so the specialist must exist before the graph is built.
  let!(:specialist) do
    create(:captain_assistant, account: account, description: 'SPECIALIST OWN PROMPT', routing_description: 'Запись на приём',
                               config: { 'tool_access' => { 'agent' => { 'enabled' => true, 'tool_ids' => %w[create_appointment handoff] } } })
  end
  let(:conversation) { create(:conversation, account: account) }
  let(:context) { { state: { account_id: account.id, assistant_id: entry.id }, conversation_history: [] } }
  let(:session) { Captain::Conversation::AgentSession.new(entry: entry, conversation: conversation) }

  after { Current.executed_by = nil }
  before { account.enable_features!('scheduling') }

  it 'does not repeat input checks when an agent is activated' do
    expect(Captain::Safety::CustomRulesRuntime).not_to receive(:check_input!)

    runtime = described_class.new(entry: entry)
    runtime.prepare(context)
    runtime.activate(specialist, context)
    runtime.activate(entry, context)
  end

  it 'builds one lazy runtime agent per candidate, with no transfers between them' do
    agents = described_class.new(entry: entry, conversation: conversation).runtime_agents

    expect(agents.map(&:name)).to contain_exactly("assistant_#{entry.id}", "assistant_#{specialist.id}")
    expect(agents).to all(satisfy { |agent| !agent.respond_to?(:handoff_agents) })
  end

  it 'chooses no agent when it prepares the run: a new conversation has none, the router decides' do
    described_class.new(entry: entry, conversation: conversation).prepare(context)

    expect(context).to include(routing_current_agent_id: nil, routing_trail: [])
    expect(context.keys).not_to include(:current_agent, :acting_assistant_id, :agent_tasks)
    expect(context[:agent_graph].pluck(:id)).to contain_exactly(entry.id, specialist.id)
    expect(context[:state][:agent_graph_ids]).to contain_exactly(entry.id, specialist.id)
    expect(context[:state][:entry_assistant_id]).to eq(entry.id)
  end

  it 'gives the router the agent that holds the conversation and the trail of the last decisions' do
    session.update_routing(actor_id: specialist.id, trail: { 'kind' => 'agent', 'to' => [specialist.id] })

    described_class.new(entry: entry, conversation: conversation.reload).prepare(context)

    expect(context[:routing_current_agent_id]).to eq(specialist.id)
    expect(context[:routing_trail]).to eq([{ 'kind' => 'agent', 'to' => [specialist.id] }])
  end

  it 'leaves the conversation without a current agent when the agent that held it was switched off' do
    session.update_routing(actor_id: specialist.id)
    specialist.update!(active: false)

    runtime = described_class.new(entry: entry.reload, conversation: conversation.reload)
    runtime.prepare(context)

    expect(context[:routing_current_agent_id]).to be_nil
    # Released in the session: the response builder reads the anchor until the router gives the conversation to an agent.
    expect(runtime.holder).to eq(entry)
    expect(session.read).to include('current_assistant_id' => nil, 'routing_revision' => 2)
    expect(Captain::Conversation::AgentOwnership.new(conversation: conversation.reload).current_actor_id).to eq(entry.id)
  end

  it 'names the agent that holds the conversation as its holder, also when the router may no longer choose it' do
    runtime = described_class.new(entry: entry, conversation: conversation)
    runtime.prepare(context)
    expect(runtime.holder).to eq(entry)

    session.update_routing(actor_id: specialist.id)
    specialist.update!(config: specialist.config.merge('patient_routing' => false))
    runtime = described_class.new(entry: entry, conversation: conversation.reload)
    runtime.prepare(context)

    expect(context[:routing_current_agent_id]).to be_nil
    expect(runtime.holder).to eq(specialist)
    expect(session.read['current_assistant_id']).to eq(specialist.id)
  end

  it 'prepares the one agent of a channel at once: there is nothing to decide' do
    specialist.update!(active: false)

    described_class.new(entry: entry, conversation: conversation).prepare(context)

    expect(context[:agent_graph]).to eq([])
    expect(context[:current_agent]).to eq("assistant_#{entry.id}")
    expect(context[:acting_assistant_id]).to eq(entry.id)
    expect(context[:state][:agent_graph_ids]).to eq([entry.id])
  end

  it 'gives a run without a channel a single agent' do
    runtime = described_class.new(entry: entry)

    expect(runtime.runtime_agents.map(&:name)).to eq(["assistant_#{entry.id}"])
    runtime.prepare(context)
    expect(context[:agent_graph]).to eq([])
    expect(context[:state][:agent_graph_ids]).to eq([entry.id])
  end

  it 'preserves the specialist own prompt' do
    runtime = described_class.new(entry: entry, conversation: conversation)
    runtime.prepare(context)
    runtime.activate(specialist, context)
    prompt = specialist.agent_instructions(Captain::Runtime::RunContext.new(context))
    expect(prompt).to include('SPECIALIST OWN PROMPT')
    expect(prompt).not_to include('ENTRY PRIVATE PROMPT')
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

    it 'shows the agent that takes the turn what was done earlier and what was done in reply to this message' do
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
  end

  describe 'what the model is given for the run' do
    def entry_agent(runtime) = runtime.runtime_agents.find { |agent| agent.assistant_id == entry.id }

    def tool_names(runtime, run_context)
      Captain::Runtime::ChatFactory.send(:build_agent_tools, entry_agent(runtime), run_context).map(&:name)
    end

    def prompt_of(runtime, run_context)
      Captain::Runtime::ChatFactory.send(:system_prompt_for, entry_agent(runtime), run_context)
    end

    it 'gives an agent of a multi-agent channel its own tools and prompt only: no plan, no transfer, no colleagues' do
      runtime = described_class.new(entry: entry, conversation: conversation)
      runtime.prepare(context)
      runtime.activate(entry, context)
      run_context = Captain::Runtime::RunContext.new(context)

      names = tool_names(runtime, run_context)
      expect(names).to include('handoff', 'faq_lookup')
      expect(names).not_to include('plan_request', 'manage_agent_tasks')
      expect(names.grep(/\Atransfer_to_|\Ahandoff_to_/)).to be_empty
      prompt = prompt_of(runtime, run_context)
      expect(prompt).to include('ENTRY PRIVATE PROMPT')
      expect(prompt).not_to match(/plan_request|Colleagues|colleague|transfer|#{Regexp.escape(specialist.name)}/)
    end
  end

  it 'takes every active text-channel agent regardless of stored handoff lists or legacy channel links' do
    entry.update!(handoff_agent_ids: [])
    outsider = create(:captain_assistant, account: account, channel_scope: 'selected', routing_description: 'Анализы')
    runtime = described_class.new(entry: entry, conversation: conversation)

    expect(runtime.runtime_agents.map(&:assistant_id)).to eq([entry.id, specialist.id, outsider.id].sort)
    expect(runtime.graph.find(outsider.id)).to eq(outsider)
  end

  it 'leaves an agent without a routing description out of the candidates' do
    undescribed = create(:captain_assistant, account: account)
    runtime = described_class.new(entry: entry, conversation: conversation)

    expect(runtime.graph.candidates.map(&:id)).to contain_exactly(entry.id, specialist.id)
    expect(runtime.graph.find(undescribed.id)).to eq(undescribed)
  end

  it 'materializes only the agent that answers' do
    runtime = described_class.new(entry: entry, conversation: conversation)
    agents = runtime.runtime_agents
    expect(agents).to all(be_a(Captain::Runtime::LazyAgent))
    expect(agents.any? { |agent| agent.instance_variable_defined?(:@materialized) }).to be(false)
    agents.first.tools
    expect(agents.first.instance_variable_defined?(:@materialized)).to be(true)
    expect(agents.last.instance_variable_defined?(:@materialized)).to be(false)
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

  it 'gives the selected playground reasoning override to the agent being tried out only' do
    runtime = described_class.new(entry: entry)
    context[:state][:playground_thinking_effort] = 'none'
    runtime.prepare(context)

    runtime.activate(entry, context)
    expect(context[:state][:playground_thinking_effort]).to eq('none')

    runtime.activate(specialist, context)
    expect(context[:state]).not_to have_key(:playground_thinking_effort)

    runtime.activate(entry, context)
    expect(context[:state][:playground_thinking_effort]).to eq('none')
    expect(context[:state][:captain_runtime]['assistant_thinking_effort']).to eq('none')
  end

  it 'retains the standalone internal-agent path' do
    entry.update!(usage_mode: 'internal_assistant')
    expect(Captain::AgentGraph.new(entry).agents).to eq([entry])
    expect(Captain::AgentGraph.new(entry).candidates).to eq([entry])
  end
end
