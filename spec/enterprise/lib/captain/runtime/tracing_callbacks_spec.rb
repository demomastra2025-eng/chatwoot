# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Runtime::TracingCallbacks do
  subject(:callbacks) { described_class.new(tracer: double('tracer'), trace_name: 'captain') } # rubocop:disable RSpec/VerifiedDoubles

  it 'puts the transfer of a colleague under the root of the trace, under its new name and under the former one in stored runs' do
    transfers = %w[transfer_to_agent_4 transfer_to_scenario_1_x_agent handoff_to_assistant_4 handoff_to_scenario_1_x_agent]

    expect(transfers.map { |name| callbacks.send(:handoff_tool?, name) }).to all(be(true))
  end

  it 'leaves every other tool, the human handoff included, under the current agent' do
    expect(%w[handoff plan_request manage_agent_tasks faq_lookup create_appointment].map { |name| callbacks.send(:handoff_tool?, name) })
      .to all(be(false))
  end
end
