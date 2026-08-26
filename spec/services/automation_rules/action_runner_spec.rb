require 'rails_helper'

RSpec.describe AutomationRules::ActionRunner do
  let(:account) { instance_double(Account, id: 7) }
  let(:rule) do
    instance_double(
      AutomationRule,
      id: 11,
      actions: [
        { 'action_id' => 'first-action', 'action_name' => 'send_message' },
        { 'action_id' => 'second-action', 'action_name' => 'add_label' }
      ]
    )
  end

  it 'records successful actions and skips them when a failed execution retries' do
    completed = {}
    tracker = instance_double(ChatwootExceptionTracker, capture_exception: nil)
    allow(ChatwootExceptionTracker).to receive(:new).and_return(tracker)
    allow(Redis::Alfred).to receive(:get) { |key| completed[key] }
    allow(Redis::Alfred).to receive(:set) do |key, value, **_options|
      completed[key] = value
      true
    end
    calls = []
    first_attempt = true
    runner = described_class.new(rule: rule, account: account, execution_key: 'event-key')

    expect do
      runner.perform do |action, _index|
        calls << action[:action_id]
        if action[:action_id] == 'first-action' && first_attempt
          first_attempt = false
          raise StandardError, 'temporary provider failure'
        end
      end
    end.to raise_error(StandardError, 'temporary provider failure')

    runner.perform { |action, _index| calls << action[:action_id] }

    expect(calls).to eq(%w[first-action second-action first-action])
    expect(tracker).to have_received(:capture_exception).once
    expect(Redis::Alfred).to have_received(:set).with(
      kind_of(String),
      true,
      ex: 30.days.to_i
    ).twice
  end
end
