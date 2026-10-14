# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Runtime::HandoffTool do
  let(:when_to_use) { described_class::WHEN_TO_USE }

  it 'emits a benchmark guard event when a transfer target is unavailable' do
    target = Captain::Runtime::Agent.new(name: 'assistant_2')
    target.assistant_id = 2
    context = { agent_request_id: 'synthetic-request', state: { account_id: 1, assistant_id: 1, source: 'benchmark',
                                                                conversation: { id: 3 } },
                agent_graph: [{ id: 1 }] }
    tool_context = Captain::Runtime::ToolContext.new(run_context: Captain::Runtime::RunContext.new(context))
    events = []
    subscriber = ActiveSupport::Notifications.subscribe('captain.agent.transfer_guard') do |*args|
      events << ActiveSupport::Notifications::Event.new(*args)
    end

    result = described_class.new(target).perform(tool_context)

    expect(Captain::ToolResult.normalize(result)).to include(success: false)
    expect(events.sole.payload).to include('reason' => 'target_not_allowed', 'from_agent_id' => 1,
                                           'to_agent_id' => 2, 'run_source' => 'benchmark',
                                           'request_id' => 'synthetic-request')
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  it 'halts neutrally after two transfers without requesting staff or a customer question' do
    entry = create(:captain_assistant)
    specialist = create(:captain_assistant, account: entry.account)
    inbox = create(:inbox, account: entry.account)
    target = Captain::Runtime::Agent.new(name: "assistant_#{specialist.id}")
    target.assistant_id = specialist.id
    context = { state: { account_id: entry.account_id, assistant_id: entry.id, entry_assistant_id: entry.id },
                agent_graph: Captain::AgentGraph.new(entry, inbox: inbox).payload, agent_inbox_id: inbox.id, handoff_count: 2 }
    tool_context = Captain::Runtime::ToolContext.new(run_context: Captain::Runtime::RunContext.new(context))

    result = described_class.new(target).perform(tool_context)

    expect(result).to be_a(RubyLLM::Tool::Halt)
    expect(result.content).to be_blank
    expect(context[:transfer_guard_active]).to be(true)
    expect(context).not_to have_key(:pending_handoff)
    expect(context).not_to have_key(:pending_human_handoff)
  end

  it 'answers an immediate return to the agent that just handed off with a result the model can act on, without a guard' do
    entry = create(:captain_assistant)
    specialist = create(:captain_assistant, account: entry.account)
    inbox = create(:inbox, account: entry.account)
    target = Captain::Runtime::Agent.new(name: "assistant_#{entry.id}")
    target.assistant_id = entry.id
    context = { agent_request_id: 'synthetic-request',
                state: { account_id: entry.account_id, assistant_id: specialist.id, entry_assistant_id: entry.id },
                agent_graph: Captain::AgentGraph.new(entry, inbox: inbox).payload,
                agent_inbox_id: inbox.id, handoff_count: 1, previous_handoff_source_id: entry.id }
    tool_context = Captain::Runtime::ToolContext.new(run_context: Captain::Runtime::RunContext.new(context))
    events = []
    subscriber = ActiveSupport::Notifications.subscribe('captain.agent.transfer_guard') do |*args|
      events << ActiveSupport::Notifications::Event.new(*args)
    end

    result = described_class.new(target).perform(tool_context)

    expect(result).not_to be_a(RubyLLM::Tool::Halt)
    expect(Captain::ToolResult.normalize(result)).to include(
      success: false, retryable: true,
      error: 'The conversation came from that colleague; transfer to the colleague who owns this request, or answer it yourself.'
    )
    expect(context).not_to include(:transfer_guard_active, :pending_handoff)
    expect(events.sole.payload).to include('reason' => 'return_to_previous_source', 'from_agent_id' => specialist.id, 'to_agent_id' => entry.id)
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  it 'refuses a transfer when the target becomes inactive' do
    entry = create(:captain_assistant)
    specialist = create(:captain_assistant, account: entry.account, channel_scope: 'selected')
    inbox = create(:inbox, account: entry.account)
    target = Captain::Runtime::Agent.new(name: "assistant_#{specialist.id}")
    target.assistant_id = specialist.id
    context = { state: { account_id: entry.account_id, assistant_id: entry.id, entry_assistant_id: entry.id },
                agent_graph: Captain::AgentGraph.new(entry, inbox: inbox).payload, agent_inbox_id: inbox.id }
    tool_context = Captain::Runtime::ToolContext.new(run_context: Captain::Runtime::RunContext.new(context))
    specialist.update!(active: false)

    result = described_class.new(target).perform(tool_context)

    expect(Captain::ToolResult.normalize(result)).to include(
      success: false, error: 'Agent routing changed; this handoff is no longer available'
    )
    expect(context).not_to have_key(:pending_handoff)
  end

  describe 'a transfer to one colleague' do
    let!(:entry) { create(:captain_assistant) }
    let!(:specialist) { create(:captain_assistant, account: entry.account) }
    let!(:inbox) { create(:inbox, account: entry.account) }
    let(:target) { Captain::Runtime::Agent.new(name: "assistant_#{specialist.id}").tap { |agent| agent.assistant_id = specialist.id } }
    let(:context) do
      { state: { account_id: entry.account_id, assistant_id: entry.id, entry_assistant_id: entry.id },
        agent_graph: Captain::AgentGraph.new(entry, inbox: inbox).payload, agent_inbox_id: inbox.id,
        agent_session: Object.new, agent_tasks: [] }
    end
    let(:run_context) { Captain::Runtime::RunContext.new(context) }
    let(:tool_context) { Captain::Runtime::ToolContext.new(run_context: run_context) }

    it 'transfers the conversation without a request plan' do
      result = described_class.new(target).perform(tool_context)

      expect(result).to be_a(RubyLLM::Tool::Halt)
      expect(result.content).to be_blank
      expect(context[:pending_handoff]).to include(target_agent: target)
      expect(context).not_to include(:part_plan_accepted, :part_plan, :transfer_guard_active)
    end

    it 'transfers through the tool wrapper with a session, no plan and no arguments' do
      wrapper = Captain::Runtime::ToolWrapper.new(described_class.new(target), run_context)

      result = wrapper.call({})

      expect(result).to be_a(RubyLLM::Tool::Halt)
      expect(context[:pending_handoff]).to include(target_agent: target)
      expect(context).not_to include(:part_plan_accepted)
    end

    it 'refuses a transfer once the message is planned, as a result the model can act on, and leaves the plan to run' do
      context[:part_plan_accepted] = true
      context[:part_plan] = { mode: 'council', parts: [] }

      result = described_class.new(target).perform(tool_context)

      expect(result).not_to be_a(RubyLLM::Tool::Halt)
      expect(Captain::ToolResult.normalize(result)).to include(
        success: false, retryable: true, error: 'This message is already planned: each agent of the plan answers its part.'
      )
      expect(context).not_to include(:pending_handoff, :transfer_guard_active)
      expect(context).to include(part_plan_accepted: true)
    end

    it 'refuses a planned message before it looks at the limit, and halts without a result only at the third transfer' do
      context[:part_plan_accepted] = true
      context[:handoff_count] = 2

      refused = described_class.new(target).perform(tool_context)
      context.delete(:part_plan_accepted)
      halted = described_class.new(target).perform(tool_context)

      expect(Captain::ToolResult.normalize(refused)).to include(success: false, retryable: true)
      expect(halted).to be_a(RubyLLM::Tool::Halt)
      expect(context[:transfer_guard_active]).to be(true)
      expect(context).not_to include(:pending_handoff)
    end

    it 'is a tool without parameters whose name identifies the colleague and whose description names it' do
      tool = described_class.new(target)

      expect(tool.parameters).to be_empty
      expect(tool.name).to eq("transfer_to_agent_#{specialist.id}")
      expect(tool.name).to eq(Captain::HandoffNaming.tool_name_for('any name', record_id: specialist.id))
      expect(tool.description).to eq(%(Transfer the conversation to colleague "assistant_#{specialist.id}". #{when_to_use}))
    end

    it 'ends with when to use it: the message holds actions of this colleague only, who also answers the questions of the message' do
      expect(when_to_use).to eq(
        'Use it when the patient\'s message holds actions of this colleague only; the colleague also answers the questions of the message.'
      )
      expect(described_class.new(target).description).to end_with(when_to_use)
      expect(when_to_use).not_to match(/\b(?:not|never|don't)\b/i)
    end

    it 'names the colleague and its responsibility in one sentence, and names a Cyrillic colleague by its id' do
      specialist.assign_attributes(name: 'Анализы', routing_description: "Подготовка к анализам,\nцены")
      allow(specialist).to receive(:selected_agent_tool_ids).and_return(%w[handoff faq_lookup])

      tool = described_class.new(Captain::Runtime::LazyAgent.new(specialist))

      expect(tool.name).to eq("transfer_to_agent_#{specialist.id}")
      expect(tool.description).to eq(%(Transfer the conversation to colleague "Анализы": Подготовка к анализам, цены. #{when_to_use}))
    end

    it 'adds one line with what the colleague can do, read from the tool ids of the assistant without building its tools' do
      specialist.assign_attributes(name: 'Продажи', routing_description: 'Сделки клиники')
      ids = %w[create_deal update_deal transition_deal_stage search_deals faq_lookup handoff]
      allow(specialist).to receive(:selected_agent_tool_ids).and_return(ids)
      lazy = Captain::Runtime::LazyAgent.new(specialist)
      expect(specialist).not_to receive(:agent)

      tool = described_class.new(lazy)

      expect(tool.description).to eq(
        %(Transfer the conversation to colleague "Продажи": Сделки клиники. ) +
        "Can: create and update deals; look up deals. #{when_to_use}"
      )
    end

    it 'adds the same line for an agent that holds its tools, and ends a title without a responsibility with a full stop' do
      names = %w[create_appointment update_appointment cancel_appointment faq_lookup search_available_slots]
      tools = names.map { |name| Struct.new(:name).new(name) }
      colleague = Captain::Runtime::Agent.new(name: 'assistant_7', tools: tools).tap { |agent| agent.assistant_id = 7 }

      expect(described_class.new(colleague).description).to eq(
        %(Transfer the conversation to colleague "assistant_7". Can: book, reschedule and cancel appointments; look up free slots. #{when_to_use})
      )
    end

    it 'leaves the line out when the colleague has no tool that says what it does, and when its tool ids cannot be read' do
      only_shared = Captain::Runtime::Agent.new(name: 'assistant_7', tools: [Struct.new(:name).new('faq_lookup')])
      broken = Captain::Runtime::Agent.new(name: 'assistant_8')
      allow(broken).to receive(:tool_ids).and_raise(StandardError, 'catalog down')

      expect(described_class.new(only_shared).description).to eq(%(Transfer the conversation to colleague "assistant_7". #{when_to_use}))
      expect(described_class.new(broken).description).to eq(%(Transfer the conversation to colleague "assistant_8". #{when_to_use}))
    end

    it 'is still named by its normalized name when the colleague has no id' do
      nameless = Captain::Runtime::Agent.new(name: 'scenario_35_billing_agent')

      expect(described_class.new(nameless).name).to eq('transfer_to_scenario_35_billing_agent')
    end

    it 'is not offered to a council part, which acts with its own tools and transfers nothing' do
      context[:part_run] = true
      acting = Captain::Runtime::Agent.new(name: "assistant_#{entry.id}", handoff_agents: [target])

      expect(Captain::Runtime::ChatFactory.send(:build_agent_tools, acting, run_context)).to be_empty
    end

    it 'is offered for every colleague of the graph, with plan_request only for the coordination' do
      colleague = target
      acting = Captain::Runtime::Agent.new(name: "assistant_#{entry.id}", handoff_agents: [colleague])

      tools = Captain::Runtime::ChatFactory.send(:build_agent_tools, acting, run_context)

      expect(tools.map(&:name)).to eq(["transfer_to_agent_#{specialist.id}", 'plan_request'])
    end

    it 'is not offered to a lone agent, which has no colleague to transfer to and no plan to make' do
      lone = Captain::Runtime::Agent.new(name: "assistant_#{entry.id}")
      context[:agent_graph] = [{ id: entry.id }]

      expect(lone.handoff_agents).to be_empty
      expect(Captain::Runtime::ChatFactory.send(:build_agent_tools, lone, run_context)).to be_empty
    end
  end
end

RSpec.describe Captain::Runtime::CoordinationEvents do
  it 'publishes council participants and outcome without message content' do
    context = { agent_request_id: 'synthetic-request', state: { account_id: 1, source: 'playground' } }
    events = []
    subscriber = ActiveSupport::Notifications.subscribe(/\Acaptain\.council\./) do |*args|
      events << ActiveSupport::Notifications::Event.new(*args)
    end

    described_class.council_started(context: context, participant_ids: [2, 3, 2])
    described_class.council_finished(context: context, participant_ids: [2, 3], outcome: 'completed')

    expect(events.map(&:name)).to eq(%w[captain.council.started captain.council.finished])
    expect(events.first.payload).to include('participants' => [2, 3], 'run_source' => 'playground')
    expect(events.last.payload).to include('participants' => [2, 3], 'outcome' => 'completed')
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  it 'publishes the editor events with identifiers, language and reason only' do
    context = { agent_request_id: 'synthetic-request', state: { account_id: 1, assistant_id: 2, conversation: { id: 3 } } }
    events = []
    subscriber = ActiveSupport::Notifications.subscribe(/\Acaptain\.council\./) do |*args|
      events << ActiveSupport::Notifications::Event.new(*args)
    end

    described_class.council_edited(context: context, part_ids: %w[part-1 part-2], language: 'kk', handoff: true)
    described_class.council_edited(context: context, part_ids: %w[part-1], language: 'ru', handoff: false)
    described_class.council_editor_fallback(context: context, part_ids: %w[part-1], reason: :invalid)

    expect(events.map(&:name)).to eq(%w[captain.council.edited captain.council.edited captain.council.editor_fallback])
    expect(events.first.payload).to include('parts' => %w[part-1 part-2], 'language' => 'kk', 'handoff' => true,
                                            'reason' => 'council_unresolved', 'conversation_id' => 3)
    expect(events.second.payload).to include('language' => 'ru', 'handoff' => false)
    expect(events.second.payload).not_to have_key('reason')
    expect(events.last.payload).to include('parts' => %w[part-1], 'reason' => 'invalid')
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  it 'never lets a failing monitor break the council reply' do
    allow(Llm::EventBus).to receive(:publish).and_raise(StandardError, 'bus down')

    expect do
      described_class.council_edited(context: {}, part_ids: [], language: 'ru', handoff: false)
      described_class.council_editor_fallback(context: {}, part_ids: [], reason: 'error')
    end.not_to raise_error
  end

  describe 'the events of a council part' do
    let(:context) do
      { agent_request_id: 'synthetic-request', state: { account_id: 1, assistant_id: 4, source: 'benchmark', conversation: { id: 3 } } }
    end
    let(:part) do
      { 'id' => 'synthetic-part', 'version' => 2, 'executor_agent_id' => 4, 'fragment' => 'PRIVATE_TEXT',
        'summary' => 'PRIVATE_SUMMARY', 'missing_fields' => ['PRIVATE_QUESTION'], 'prior_summary' => 'PRIVATE_PRIOR' }
    end
    let(:events) { [] }

    around do |example|
      subscriber = ActiveSupport::Notifications.subscribe(/\Acaptain\.(council|tool)\./) do |*args|
        events << ActiveSupport::Notifications::Event.new(*args)
      end
      example.run
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
    end

    it 'publishes the start and the end of a part with identifiers, states and counts, without text or parameters' do
      described_class.part_started(context: context, part: part, lane: 'writer', inline: true)
      described_class.part_finished(context: context, part: part, state: :done, status: 'answered', acted: true, mutations_succeeded: 1,
                                    mutations_failed: 0, mutations_unknown: 0, tools_called: 4, turns: 3, duration_ms: 1200)

      expect(events.map(&:name)).to eq(%w[captain.council.part_started captain.council.part_finished])
      expect(events.first.payload).to include('part_id' => 'synthetic-part', 'part_version' => 2, 'executor_agent_id' => 4,
                                              'lane' => 'writer', 'inline' => true, 'run_source' => 'benchmark', 'conversation_id' => 3)
      expect(events.last.payload).to include('state' => 'done', 'status' => 'answered', 'acted' => true, 'mutations_succeeded' => 1,
                                             'mutations_failed' => 0, 'mutations_unknown' => 0, 'tools_called' => 4, 'turns' => 3,
                                             'duration_ms' => 1200)
      expect(events.map { |event| event.payload.to_json }.join).not_to include('PRIVATE')
    end

    it 'publishes a technical failure with the names and codes of what failed, never an argument or a message' do
      failure = { 'tool' => 'create_appointment', 'kind' => 'technical', 'stage' => 'tool_execution', 'reason' => 'provider_unavailable',
                  'mutating' => true, 'error' => 'PRIVATE_MESSAGE' }

      described_class.technical_failure(context: context, failure: failure)

      expect(events.map(&:name)).to eq(%w[captain.tool.technical_failure])
      expect(events.sole.payload).to include('tool_name' => 'create_appointment', 'stage' => 'tool_execution',
                                             'reason' => 'provider_unavailable', 'mutating' => true, 'run_source' => 'benchmark')
      expect(events.sole.payload.to_json).not_to include('PRIVATE')
    end

    it 'never lets a failing monitor break a part' do
      allow(Llm::EventBus).to receive(:publish).and_raise(StandardError, 'bus down')

      expect do
        described_class.part_started(context: {}, part: part, lane: 'reader', inline: false)
        described_class.technical_failure(context: {}, failure: {})
      end.not_to raise_error
    end

    it 'has no operation events any more: a part acts with its own tools' do
      expect(described_class).not_to respond_to(:operation_started, :operation_finished)
    end
  end
end
