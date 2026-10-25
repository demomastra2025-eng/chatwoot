# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Runtime::TracingCallbacks do
  subject(:callbacks) { described_class.new(tracer: double('tracer'), trace_name: 'captain') } # rubocop:disable RSpec/VerifiedDoubles

  it 'names the decision of the router on the root span of the trace, identifiers only' do
    wrapper = Captain::Runtime::RunContext.new({ routing_decision: { decision_key: 'route_agent_4', decided_by: 'inception/mercury-decide' } })

    attributes = callbacks.send(:build_root_attributes, 'assistant_4', 'текст пациента', wrapper)

    expect(attributes).to include('routing.decision_key' => 'route_agent_4', 'routing.decided_by' => 'inception/mercury-decide')
  end

  it 'has no transfer tools to place under the root of the trace' do
    expect(described_class.private_method_defined?(:handoff_tool?)).to be(false)
  end
end
