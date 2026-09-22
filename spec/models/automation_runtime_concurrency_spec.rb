require 'rails_helper'

# rubocop:disable RSpec/DescribeClass
RSpec.describe 'Automation runtime uniqueness under concurrent writers' do
  self.use_transactional_tests = false

  let!(:account) { create(:account) }

  after do
    AutomationActionReceipt.where(account_id: account.id).delete_all
    AutomationExecution.where(account_id: account.id).delete_all
    AutomationEvent.where(account_id: account.id).delete_all
    AutomationRule.where(account_id: account.id).delete_all
    AutomationRuleGroup.where(account_id: account.id).delete_all
    Account.where(id: account.id).delete_all
  end

  it 'allows only one event for an account dedupe key' do
    attributes = attributes_for(:automation_event, account: account).merge(account_id: account.id, dedupe_key: 'same-event')

    results = race_create { AutomationEvent.create!(attributes) }

    expect(results.count { |result| result.is_a?(AutomationEvent) }).to eq(1)
    expect(results.count { |result| unique_violation?(result) }).to eq(1)
    expect(AutomationEvent.where(account: account, dedupe_key: 'same-event').count).to eq(1)
  end

  it 'returns the same winner to concurrent idempotent capture callers' do
    conversation = create(:conversation, account: account)
    AutomationEvent.where(account: account).delete_all
    envelope = {
      account: account,
      event_name: 'conversation_updated',
      subject: conversation,
      payload_snapshot: { snapshot_version: 1 },
      producer: 'concurrency_spec',
      provenance: { source: 'spec' },
      dedupe_key: 'concurrent-capture'
    }

    results = race_create { AutomationRules::Events::CaptureService.capture!(**envelope) }

    expect(results).to all(be_a(AutomationEvent))
    expect(results.map(&:id).uniq.one?).to be(true)
    expect(AutomationEvent.where(account: account, dedupe_key: 'concurrent-capture').count).to eq(1)
  end

  it 'allows only one selected rule per event and first-match group' do
    group = create(:automation_rule_group, account: account)
    rules = [0, 1].map { |position| create(:automation_rule, account: account, automation_rule_group: group, position: position) }
    event = create(:automation_event, account: account)

    results = race_create do |index|
      rule = rules.fetch(index)
      create(:automation_execution, account: account, automation_event: event, automation_rule: rule, automation_rule_group: group)
    end

    expect(results.count { |result| result.is_a?(AutomationExecution) }).to eq(1)
    expect(results.count { |result| unique_violation?(result) }).to eq(1)
    expect(AutomationExecution.where(automation_event: event, automation_rule_group: group).count).to eq(1)
  end

  it 'allows only one receipt for an execution action identity' do
    execution = create(:automation_execution, account: account, actions_snapshot: [{ 'action_name' => 'assign_team' }])

    results = race_create do
      create(:automation_action_receipt, account: account, automation_execution: execution, action_id: 'legacy-index:0')
    end

    expect(results.count { |result| result.is_a?(AutomationActionReceipt) }).to eq(1)
    expect(results.count { |result| unique_violation?(result) }).to eq(1)
    expect(AutomationActionReceipt.where(automation_execution: execution, action_id: 'legacy-index:0').count).to eq(1)
  end

  def race_create
    barrier = Concurrent::CyclicBarrier.new(2)
    Array.new(2) do |index|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          barrier.wait
          yield(index)
        rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
          e
        end
      end
    end.map(&:value)
  end

  def unique_violation?(result)
    result.is_a?(ActiveRecord::RecordNotUnique) ||
      (result.is_a?(ActiveRecord::RecordInvalid) && result.record.errors.details.values.flatten.any? { |error| error[:error] == :taken })
  end
end
# rubocop:enable RSpec/DescribeClass
