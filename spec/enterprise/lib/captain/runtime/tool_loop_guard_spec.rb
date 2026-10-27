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

  describe '#first_strike?' do
    let(:guard) { described_class.new(context, 'search') }

    it 'is true for the first step with a refusal and for every refusal of that step' do
      expect(guard.first_strike?('step-1')).to be(true)
      expect(guard.first_strike?('step-1')).to be(true)
      expect(context.context[described_class::WARNED_BATCH_KEY]).to eq('step-1')
    end

    it 'is false for a refusal in a later step' do
      guard.first_strike?('step-1')

      expect(guard.first_strike?('step-2')).to be(false)
      expect(guard.first_strike?('step-1')).to be(true)
    end

    it 'is never true for a step that cannot be told apart' do
      expect(guard.first_strike?(nil)).to be(false)
      expect(guard.first_strike?('')).to be(false)
      expect(context.context).not_to have_key(described_class::WARNED_BATCH_KEY)
    end

    it 'is shared by the tools of one run' do
      described_class.new(context, 'other').first_strike?('step-1')

      expect(guard.first_strike?('step-2')).to be(false)
    end
  end
end
