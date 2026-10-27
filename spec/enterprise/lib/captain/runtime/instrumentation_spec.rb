# frozen_string_literal: true

require 'rails_helper'

# The trace of a run (OpenTelemetry) is told every event the runner emits, except those it has no handler for: the pieces of the
# answer, which only a reply suggestion listens to.
RSpec.describe Captain::Runtime::Instrumentation do
  it 'registers the events that the tracing callbacks handle and leaves the answer pieces out' do
    registered = []
    runner = Object.new
    Captain::Runtime::CallbackManager::EVENT_TYPES.each do |event|
      runner.define_singleton_method(:"on_#{event}") { |&_block| registered << event }
    end

    described_class.install(runner, tracer: Object.new, trace_name: 'spec')

    expect(registered).to include(:run_start, :tool_start, :llm_call_complete)
    expect(registered).not_to include(:answer_delta)
  end
end
