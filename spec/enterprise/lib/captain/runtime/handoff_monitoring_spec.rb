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

  describe 'the request plan of a transfer' do
    let!(:entry) { create(:captain_assistant) }
    let!(:specialist) { create(:captain_assistant, account: entry.account) }
    let(:target) { Captain::Runtime::Agent.new(name: "assistant_#{specialist.id}").tap { |agent| agent.assistant_id = specialist.id } }
    let(:context) do
      { state: { account_id: entry.account_id, assistant_id: entry.id, entry_assistant_id: entry.id },
        agent_graph: Captain::AgentGraph.new(entry).payload, agent_session: Object.new, agent_tasks: [] }
    end
    let(:tool_context) { Captain::Runtime::ToolContext.new(run_context: Captain::Runtime::RunContext.new(context)) }

    it 'refuses to transfer the conversation before the message is planned' do
      result = described_class.new(target).perform(tool_context)

      expect(Captain::ToolResult.normalize(result)).to include(success: false, error: 'Plan the request before handing it to another agent')
      expect(context).not_to have_key(:pending_handoff)
      # the runner then refuses a plain reply that would claim the transfer
      expect(context[:part_plan_refused]).to be(true)
    end

    it 'transfers the conversation once the message is planned' do
      context[:part_plan_accepted] = true

      result = described_class.new(target).perform(tool_context)

      expect(result).to be_a(RubyLLM::Tool::Halt)
      expect(context[:pending_handoff]).to include(target_agent: target)
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
