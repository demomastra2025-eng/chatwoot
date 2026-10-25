require 'rails_helper'

RSpec.describe Captain::Runtime::ToolLoopGuard do
  let(:context) { Captain::Runtime::RunContext.new({}) }

  it 'keeps the control tools outside the ordinary budget while bounding them' do
    guard = described_class.new(context, 'handoff', coordination: true)
    64.times { |index| expect(guard.register_request(signature: index.to_s)).to be_nil }
    expect(guard.register_request(signature: '65').dig(:audit, :failure_reason)).to eq('tool_request_limit')
    expect(described_class.new(context, 'search').register_request(signature: 's')).to be_nil
  end

  it 'bounds the requests of one run' do
    16.times { |index| expect(described_class.new(context, "tool_#{index % 8}").register_request(signature: index.to_s)).to be_nil }

    expect(described_class.new(context, 'tool_9').register_request(signature: 'x').dig(:audit, :failure_reason)).to eq('tool_request_limit')
  end

  it 'retains the ordinary single-request tool cap' do
    guard = described_class.new(context, 'search')
    6.times { |index| expect(guard.register_request(signature: index.to_s)).to be_nil }
    expect(guard.register_request(signature: '7').dig(:audit, :failure_reason)).to eq('tool_request_limit')
  end
end
