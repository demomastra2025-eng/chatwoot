require 'rails_helper'

# rubocop:disable RSpec/DescribeClass
RSpec.describe 'Automation runtime database contract' do
  let(:account) { create(:account) }

  it 'has the required unique and partial indexes', :aggregate_failures do
    indexes = %i[automation_events automation_rules automation_executions automation_action_receipts].index_with do |table|
      ActiveRecord::Base.connection.indexes(table).index_by(&:name)
    end

    expect(indexes[:automation_events]['idx_automation_events_on_account_dedupe'].unique).to be(true)
    expect(indexes[:automation_events]['idx_automation_events_ready'].where).to include('pending', 'retrying')
    expect(indexes[:automation_events]['idx_automation_events_expired_lease'].where).to include('processing')
    expect(indexes[:automation_events]['idx_automation_events_dead'].where).to include('dead')
    expect(indexes[:automation_rules]['idx_automation_rules_on_group_position'].unique).to be(true)
    expect(indexes[:automation_executions]['idx_automation_executions_on_event_rule_generation'].unique).to be(true)
    expect(indexes[:automation_executions]['idx_automation_executions_on_event_group_selection'].unique).to be(true)
    expect(indexes[:automation_executions]['idx_automation_executions_on_event_group_selection'].where).to include('IS NOT NULL')
    expect(indexes[:automation_executions]['idx_automation_executions_expired_lease'].where).to include('processing')
    expect(indexes[:automation_action_receipts]['idx_automation_action_receipts_on_execution_action'].unique).to be(true)
    expect(indexes[:automation_action_receipts]['idx_automation_action_receipts_expired_lease'].where).to include('processing')
  end

  it 'rejects cross-account execution foreign-key paths even when model validation is bypassed' do
    other_account = create(:account)
    event = create(:automation_event, account: account)
    rule = create(:automation_rule, account: other_account)
    execution = build(:automation_execution, account: account, automation_event: event, automation_rule: rule)

    expect { execution.save!(validate: false) }.to raise_error(ActiveRecord::InvalidForeignKey)
  end

  it 'rejects a cross-account receipt path even when model validation is bypassed' do
    execution = create(:automation_execution, account: account)
    receipt = build(
      :automation_action_receipt,
      account: create(:account),
      automation_execution: execution,
      action_id: 'legacy-index:0'
    )

    expect { receipt.save!(validate: false) }.to raise_error(ActiveRecord::InvalidForeignKey)
  end

  it 'enforces grouped position and event consistency in PostgreSQL' do
    group = create(:automation_rule_group, account: account, event_name: 'conversation_updated')
    rule = create(:automation_rule, account: account)

    expect do
      AutomationRule.transaction(requires_new: true) do
        rule.update_columns(automation_rule_group_id: group.id, position: nil) # rubocop:disable Rails/SkipsModelValidations
      end
    end.to raise_error(ActiveRecord::StatementInvalid, /automation_rules_group_position_complete/)

    expect do
      AutomationRule.transaction(requires_new: true) do
        rule.update_columns( # rubocop:disable Rails/SkipsModelValidations
          automation_rule_group_id: group.id,
          position: 0,
          event_name: 'conversation_created'
        )
      end
    end.to raise_error(ActiveRecord::InvalidForeignKey)
  end

  it 'enforces immutable event and execution snapshots in PostgreSQL' do
    event = create(:automation_event, account: account)
    execution = create(:automation_execution, account: account, automation_event: event)
    receipt = create(:automation_action_receipt, account: account, automation_execution: execution)

    expect do
      AutomationEvent.transaction(requires_new: true) do
        event.update_column(:payload_snapshot, { forged: true }) # rubocop:disable Rails/SkipsModelValidations
      end
    end.to raise_error(ActiveRecord::StatementInvalid, /automation event envelope is immutable/)
    expect do
      AutomationExecution.transaction(requires_new: true) do
        execution.update_column(:actions_snapshot, []) # rubocop:disable Rails/SkipsModelValidations
      end
    end.to raise_error(ActiveRecord::StatementInvalid, /automation execution snapshot is immutable/)
    expect do
      AutomationActionReceipt.transaction(requires_new: true) do
        receipt.update_column(:action_id, 'replacement') # rubocop:disable Rails/SkipsModelValidations
      end
    end.to raise_error(ActiveRecord::StatementInvalid, /automation action receipt identity is immutable/)
  end

  it 'allows operational state transitions without mutating immutable snapshots' do
    event = create(:automation_event, account: account)
    execution = create(:automation_execution, account: account, automation_event: event)

    event.update!(status: 'processing', attempts: 1, lease_owner: 'event-worker', lease_expires_at: 1.minute.from_now)
    execution.update!(status: 'processing', attempts: 1, lease_owner: 'execution-worker', lease_expires_at: 1.minute.from_now)

    expect(event.reload).to be_processing
    expect(execution.reload).to be_processing
  end

  it 'rejects a rule/group mismatch on execution insert but preserves the historical selection after a rule move' do
    original_group = create(:automation_rule_group, account: account)
    new_group = create(:automation_rule_group, account: account)
    rule = create(:automation_rule, account: account, automation_rule_group: original_group, position: 0)
    event = create(:automation_event, account: account)
    poisoned = build(
      :automation_execution,
      account: account,
      automation_event: event,
      automation_rule: rule,
      automation_rule_group: new_group
    )

    expect do
      AutomationExecution.transaction(requires_new: true) { poisoned.save!(validate: false) }
    end.to raise_error(ActiveRecord::StatementInvalid, /group must match selected rule group/)

    execution = create(
      :automation_execution,
      account: account,
      automation_event: event,
      automation_rule: rule,
      automation_rule_group: original_group
    )
    rule.update!(automation_rule_group: new_group, position: 0)

    expect(execution.reload.automation_rule_group).to eq(original_group)
  end

  it 'derives receipt identity at insert and rejects caller mismatches even without validations' do
    execution = create(
      :automation_execution,
      account: account,
      actions_snapshot: [{ 'action_id' => 'snapshot-id', 'action_name' => 'assign_team' }]
    )
    forged = build(
      :automation_action_receipt,
      account: account,
      automation_execution: execution,
      action_id: 'forged',
      action_signature: 'forged'
    )

    expect do
      AutomationActionReceipt.transaction(requires_new: true) { forged.save!(validate: false) }
    end.to raise_error(ActiveRecord::StatementInvalid, /id does not match execution snapshot/)

    derived = build(
      :automation_action_receipt,
      account: account,
      automation_execution: execution,
      action_id: nil,
      action_signature: nil
    )
    derived.save!(validate: false)
    expect(derived.reload.action_id).to eq('snapshot-id')
    expect(derived.action_signature).to eq(execution.action_signature_at(0))
  end

  it 'rejects duplicate explicit action ids in PostgreSQL' do
    execution = build(
      :automation_execution,
      account: account,
      actions_snapshot: [{ 'action_id' => 'duplicate' }, { 'action_id' => 'duplicate' }]
    )

    expect do
      AutomationExecution.transaction(requires_new: true) { execution.save!(validate: false) }
    end.to raise_error(ActiveRecord::StatementInvalid, /explicit action ids must be unique/)
  end

  it 'enforces status and lease coherence in PostgreSQL for every claimable ledger' do
    event = create(:automation_event, account: account)
    execution = create(:automation_execution, account: account, automation_event: event)
    receipt = create(:automation_action_receipt, account: account, automation_execution: execution)

    [[event, AutomationEvent], [execution, AutomationExecution], [receipt, AutomationActionReceipt]].each do |record, model|
      expect do
        model.transaction(requires_new: true) do
          record.update_columns(status: 'processing', lease_owner: nil, lease_expires_at: nil) # rubocop:disable Rails/SkipsModelValidations
        end
      end.to raise_error(ActiveRecord::StatementInvalid, /status_lease_coherence/)
    end
  end

  it 'enforces resolvable account-consistent causation, trace and depth in PostgreSQL' do
    parent = create(:automation_event, account: account)
    valid_child = build(
      :automation_event,
      account: account,
      causation_id: parent.event_uuid,
      trace_id: parent.trace_id,
      depth: 1
    )
    valid_child.save!(validate: false)
    expect(valid_child.reload.causation_event).to eq(parent)

    wrong_trace = build(:automation_event, account: account, causation_id: parent.event_uuid, depth: 1)
    expect do
      AutomationEvent.transaction(requires_new: true) { wrong_trace.save!(validate: false) }
    end.to raise_error(ActiveRecord::StatementInvalid, /preserve trace and increment depth/)

    cross_account = build(
      :automation_event,
      account: create(:account),
      causation_id: parent.event_uuid,
      trace_id: parent.trace_id,
      depth: 1
    )
    expect do
      AutomationEvent.transaction(requires_new: true) { cross_account.save!(validate: false) }
    end.to raise_error(ActiveRecord::InvalidForeignKey, /causation parent does not exist in account/)
  end

  it 'rejects malformed or omitted immutable JSON snapshots in PostgreSQL' do
    malformed_event = build(:automation_event, account: account, payload_snapshot: [], provenance: [])
    expect do
      AutomationEvent.transaction(requires_new: true) { malformed_event.save!(validate: false) }
    end.to raise_error(ActiveRecord::StatementInvalid)

    malformed_execution = build(:automation_execution, account: account, actions_snapshot: {})
    expect do
      AutomationExecution.transaction(requires_new: true) { malformed_execution.save!(validate: false) }
    end.to raise_error(ActiveRecord::StatementInvalid)

    columns = AutomationExecution.columns_hash.values_at('conditions_snapshot', 'actions_snapshot', 'execution_schedule_snapshot')
    expect(columns.map(&:default)).to eq([nil, nil, nil])
  end
end
# rubocop:enable RSpec/DescribeClass
