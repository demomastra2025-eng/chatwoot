require 'rails_helper'

RSpec.describe Captain::Runtime::ToolLoopGuard do
  let(:context) { Captain::Runtime::RunContext.new({}) }

  it 'keeps coordination calls outside the ordinary domain budget while bounding them' do
    guard = described_class.new(context, 'manage_agent_tasks', coordination: true)
    64.times { |index| expect(guard.register_request(signature: index.to_s)).to be_nil }
    expect(guard.register_request(signature: '65').dig(:audit, :failure_reason)).to eq('tool_request_limit')
    expect(described_class.new(context, 'search', task_scope: 'task:one').register_request(signature: 's')).to be_nil
  end

  it 'gives each independent request its own bounded budget without resetting a previous task' do
    30.times do |index|
      guard = described_class.new(context, 'create_appointment', task_scope: "task:#{index}")
      6.times { |attempt| expect(guard.register_request(signature: "#{index}:#{attempt}")).to be_nil }
    end
    retried = described_class.new(context, 'create_appointment', task_scope: 'task:0')
    expect(retried.register_request(signature: 'changed').dig(:audit, :failure_reason)).to eq('tool_request_limit')
  end

  it 'retains the ordinary single-request tool cap' do
    guard = described_class.new(context, 'search')
    6.times { |index| expect(guard.register_request(signature: index.to_s)).to be_nil }
    expect(guard.register_request(signature: '7').dig(:audit, :failure_reason)).to eq('tool_request_limit')
  end
end
