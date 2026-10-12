# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Runtime::HandoffTool do
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
    target = Captain::Runtime::Agent.new(name: "assistant_#{specialist.id}")
    target.assistant_id = specialist.id
    context = { state: { account_id: entry.account_id, assistant_id: entry.id, entry_assistant_id: entry.id },
                agent_graph: Captain::AgentGraph.new(entry).payload, handoff_count: 2 }
    tool_context = Captain::Runtime::ToolContext.new(run_context: Captain::Runtime::RunContext.new(context))

    result = described_class.new(target).perform(tool_context)

    expect(result).to be_a(RubyLLM::Tool::Halt)
    expect(result.content).to be_blank
    expect(context[:transfer_guard_active]).to be(true)
    expect(context).not_to have_key(:pending_handoff)
    expect(context).not_to have_key(:pending_human_handoff)
  end

  it 'prevents an immediate return to the agent that just handed off' do
    entry = create(:captain_assistant)
    specialist = create(:captain_assistant, account: entry.account)
    target = Captain::Runtime::Agent.new(name: "assistant_#{entry.id}")
    target.assistant_id = entry.id
    context = { state: { account_id: entry.account_id, assistant_id: specialist.id,
                         entry_assistant_id: entry.id }, agent_graph: Captain::AgentGraph.new(entry).payload,
                handoff_count: 1, previous_handoff_source_id: entry.id }
    tool_context = Captain::Runtime::ToolContext.new(run_context: Captain::Runtime::RunContext.new(context))

    result = described_class.new(target).perform(tool_context)

    expect(result.content).to be_blank
    expect(context[:transfer_guard_active]).to be(true)
    expect(context).not_to have_key(:pending_handoff)
  end

  describe 'a transfer to one colleague' do
    let!(:entry) { create(:captain_assistant) }
    let!(:specialist) { create(:captain_assistant, account: entry.account) }
    let(:target) { Captain::Runtime::Agent.new(name: "assistant_#{specialist.id}").tap { |agent| agent.assistant_id = specialist.id } }
    let(:context) do
      { state: { account_id: entry.account_id, assistant_id: entry.id, entry_assistant_id: entry.id },
        agent_graph: Captain::AgentGraph.new(entry).payload, agent_session: Object.new, agent_tasks: [] }
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

    it 'is a tool without parameters whose name identifies the colleague and whose description names it' do
      tool = described_class.new(target)

      expect(tool.parameters).to be_empty
      expect(tool.name).to eq(Captain::HandoffNaming.tool_name_for("assistant_#{specialist.id}"))
      expect(tool.description).to start_with('Transfer the conversation to assistant_')
    end

    it 'is refused in a consultation, which can only read' do
      context[:consult_mode] = true
      wrapper = Captain::Runtime::ToolWrapper.new(described_class.new(target), run_context)

      result = wrapper.call({})
      rendered = result.is_a?(RubyLLM::Tool::Halt) ? result.content : result

      expect(JSON.parse(rendered.delete_prefix('ERROR: '))).to include('error' => 'Tool is unavailable in consult mode')
      expect(context).not_to have_key(:pending_handoff)
    end

    it 'is offered for every colleague of the graph, with plan_request only for the coordination' do
      colleague = target
      acting = Captain::Runtime::Agent.new(name: "assistant_#{entry.id}", handoff_agents: [colleague])

      tools = Captain::Runtime::ChatFactory.send(:build_agent_tools, acting, run_context)

      expect(tools.map(&:name)).to eq([Captain::HandoffNaming.tool_name_for(colleague.name), 'plan_request'])
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

  it 'publishes the composer events with identifiers, language and reason only' do
    context = { agent_request_id: 'synthetic-request', state: { account_id: 1, assistant_id: 2, conversation: { id: 3 } } }
    events = []
    subscriber = ActiveSupport::Notifications.subscribe(/\Acaptain\.council\./) do |*args|
      events << ActiveSupport::Notifications::Event.new(*args)
    end

    described_class.council_composed(context: context, part_ids: %w[part-1 part-2], language: 'kk', handoff: true)
    described_class.council_composed(context: context, part_ids: %w[part-1], language: 'ru', handoff: false)
    described_class.council_composer_fallback(context: context, part_ids: %w[part-1], reason: :invalid)

    expect(events.map(&:name)).to eq(%w[captain.council.composed captain.council.composed captain.council.composer_fallback])
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
      described_class.council_composed(context: {}, part_ids: [], language: 'ru', handoff: false)
      described_class.council_composer_fallback(context: {}, part_ids: [], reason: 'error')
    end.not_to raise_error
  end

  it 'publishes operation events with identifiers and the outcome state, without text or parameters' do
    context = { agent_request_id: 'synthetic-request',
                state: { account_id: 1, assistant_id: 4, source: 'benchmark', conversation: { id: 3 } } }
    part = { 'id' => 'synthetic-part', 'version' => 2, 'executor_agent_id' => 4, 'fragment' => 'PRIVATE_TEXT',
             'proposed_operation' => { 'type' => 'create_appointment', 'params' => { 'note' => 'PRIVATE_PARAM' } } }
    events = []
    subscriber = ActiveSupport::Notifications.subscribe(/\Acaptain\.operation\./) do |*args|
      events << ActiveSupport::Notifications::Event.new(*args)
    end

    described_class.operation_started(context: context, part: part, tool_name: 'create_appointment')
    described_class.operation_finished(context: context, part: part, tool_name: 'create_appointment', state: :unknown)

    expect(events.map(&:name)).to eq(%w[captain.operation.started captain.operation.finished])
    expect(events.last.payload).to include('part_id' => 'synthetic-part', 'part_version' => 2, 'executor_agent_id' => 4,
                                           'tool_name' => 'create_appointment', 'state' => 'unknown', 'run_source' => 'benchmark')
    expect(events.map { |event| event.payload.to_json }.join).not_to include('PRIVATE_TEXT', 'PRIVATE_PARAM')
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end
end
