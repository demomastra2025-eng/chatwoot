require 'rails_helper'

RSpec.describe AutomationRules::ExecuteRuleJob do
  let(:account) { create(:account) }
  let(:conversation) { create(:conversation, account: account) }
  let(:rule) { create(:automation_rule, account: account) }
  let(:execution_service) { instance_double(AutomationRules::ExecutionService, perform_actions: nil) }

  before do
    allow(AutomationRules::ExecutionService).to receive(:new).and_return(execution_service)
  end

  it 'executes an unchanged active rule for the original account record' do
    described_class.perform_now(
      rule.id,
      rule.execution_signature,
      conversation.to_global_id.to_s,
      { 'status' => %w[open resolved] }
    )

    expect(AutomationRules::ExecutionService).to have_received(:new).with(
      rule: rule,
      record: conversation,
      changed_attributes: { 'status' => %w[open resolved] },
      trigger_message: nil,
      execution_key: nil
    )
    expect(execution_service).to have_received(:perform_actions)
  end

  it 'executes after an unrelated rule update' do
    execution_signature = rule.execution_signature
    rule.update!(description: 'Updated description')

    described_class.perform_now(
      rule.id,
      execution_signature,
      conversation.to_global_id.to_s
    )

    expect(execution_service).to have_received(:perform_actions)
  end

  it 'does not execute after execution behavior changes' do
    execution_signature = rule.execution_signature
    rule.update!(actions: [{ action_name: 'add_label', action_params: ['vip'] }])

    described_class.perform_now(
      rule.id,
      execution_signature,
      conversation.to_global_id.to_s
    )

    expect(AutomationRules::ExecutionService).not_to have_received(:new)
  end

  it 'does not execute a queued event from an older lifecycle generation' do
    queued_generation = rule.lifecycle_generation
    rule.update!(active: false)
    rule.update!(active: true)

    described_class.perform_now(
      rule.id,
      rule.execution_signature,
      conversation.to_global_id.to_s,
      {},
      nil,
      'stale-generation-key',
      queued_generation
    )

    expect(AutomationRules::ExecutionService).not_to have_received(:new)
  end

  it 'marks a delayed execution complete only after actions succeed' do
    completed = false
    allow(Redis::Alfred).to receive(:get) { completed ? 'true' : nil }
    allow(Redis::Alfred).to receive(:set) do |key, *_args, **_options|
      completed = true if key.end_with?(':completed')
      true
    end
    arguments = [
      rule.id,
      rule.execution_signature,
      conversation.to_global_id.to_s,
      {},
      nil,
      'stable-execution-key'
    ]

    described_class.perform_now(*arguments)
    described_class.perform_now(*arguments)

    expect(Redis::Alfred).to have_received(:set).with(
      "automation_rule_execution:#{account.id}:#{rule.id}:stable-execution-key:completed",
      true,
      ex: 30.days.to_i
    ).once
    expect(execution_service).to have_received(:perform_actions).once
  end

  it 'releases the advisory lock and allows retry after an action error' do
    allow(Redis::Alfred).to receive(:get).and_return(nil)
    allow(Redis::Alfred).to receive(:set).and_return(true)
    allow(execution_service).to receive(:perform_actions).and_raise(StandardError, 'temporary failure')
    arguments = [
      rule.id,
      rule.execution_signature,
      conversation.to_global_id.to_s,
      {},
      nil,
      'retryable-execution-key'
    ]

    expect { described_class.perform_now(*arguments) }.to raise_error(StandardError, 'temporary failure')
    allow(execution_service).to receive(:perform_actions).and_return(nil)
    described_class.perform_now(*arguments)

    expect(execution_service).to have_received(:perform_actions).twice
  end

  it 'retries instead of overlapping an execution that holds the advisory lock' do
    connection = instance_double(ActiveRecord::ConnectionAdapters::PostgreSQLAdapter)
    allow(Redis::Alfred).to receive(:get).and_return(nil)
    allow(AutomationRule.connection_pool).to receive(:with_connection).and_yield(connection)
    allow(connection).to receive(:select_value).and_return(false)

    expect do
      described_class.perform_now(
        rule.id,
        rule.execution_signature,
        conversation.to_global_id.to_s,
        {},
        nil,
        'locked-execution-key'
      )
    end.to raise_error(described_class::ExecutionInProgressError)

    expect(execution_service).not_to have_received(:perform_actions)
  end
end
