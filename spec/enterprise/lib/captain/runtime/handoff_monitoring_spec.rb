# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Runtime::HandoffTool do
  it 'emits a benchmark guard event when a transfer target is unavailable' do
    target = Captain::Runtime::Agent.new(name: 'assistant_2')
    target.assistant_id = 2
    context = { agent_request_id: 'synthetic-request', state: { account_id: 1, assistant_id: 1, source: 'benchmark',
                                                                conversation: { id: 3 } },
                agent_graph: [{ id: 1, target_ids: [] }] }
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
end
