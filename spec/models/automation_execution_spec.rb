require 'rails_helper'

RSpec.describe AutomationExecution do
  it 'builds a valid execution from the factory' do
    expect(build(:automation_execution)).to be_valid
  end

  it 'uses explicit action ids and stable legacy position fallbacks' do
    execution = build(
      :automation_execution,
      actions_snapshot: [{ 'action_id' => 'stable-id' }, { 'action_name' => 'assign_team' }]
    )

    expect(execution.action_identity_at(0)).to eq('stable-id')
    expect(execution.action_identity_at(1)).to eq('legacy-index:1')
  end

  it 'rejects cross-account associations and a group different from the selected rule' do
    account = create(:account)
    other_account = create(:account)
    rule = create(:automation_rule, account: account)
    other_group = create(:automation_rule_group, account: other_account)
    execution = build(
      :automation_execution,
      account: account,
      automation_rule: rule,
      automation_event: create(:automation_event, account: other_account),
      automation_rule_group: other_group
    )

    expect(execution).not_to be_valid
    expect(execution.errors[:automation_event]).to be_present
    expect(execution.errors[:automation_rule_group]).to be_present
  end

  it 'allows runtime state changes but rejects snapshot changes' do
    execution = create(:automation_execution)

    expect(execution.update(status: 'processing', attempts: 1, lease_owner: 'worker-1', lease_expires_at: 1.minute.from_now)).to be(true)

    execution.actions_snapshot = []
    expect(execution).not_to be_valid
    expect(execution.errors[:base]).to include(/actions_snapshot/)
  end

  it 'rejects duplicate or malformed explicit action ids' do
    duplicate = build(:automation_execution, actions_snapshot: [{ 'action_id' => 'same' }, { 'action_id' => 'same' }])
    blank = build(:automation_execution, actions_snapshot: [{ 'action_id' => '' }])
    nil_id = build(:automation_execution, actions_snapshot: [{ 'action_id' => nil }])
    non_string = build(:automation_execution, actions_snapshot: [{ 'action_id' => 123 }])

    expect(duplicate).not_to be_valid
    expect(blank).not_to be_valid
    expect(nil_id).not_to be_valid
    expect(non_string).not_to be_valid
  end

  it 'derives stable signatures from the complete immutable action snapshot' do
    execution = create(:automation_execution, actions_snapshot: [{ 'action_id' => 'stable-id', 'action_name' => 'assign_team' }])

    expect(execution.action_signature_at(0)).to match(/\A[0-9a-f]{64}\z/)
    expect(execution.action_signature_at(0)).not_to eq(
      build(:automation_execution, actions_snapshot: [{ 'action_id' => 'stable-id', 'action_name' => 'assign_agent' }]).action_signature_at(0)
    )
  end

  it 'requires status-coherent leases and recovers expired processing rows' do
    pending_with_lease = build(:automation_execution, lease_owner: 'worker-1', lease_expires_at: 1.minute.from_now)
    processing_without_lease = build(:automation_execution, status: 'processing')
    expired = create(:automation_execution, status: 'processing', lease_owner: 'dead-worker', lease_expires_at: 1.minute.ago)
    active = create(:automation_execution, status: 'processing', lease_owner: 'live-worker', lease_expires_at: 1.minute.from_now)

    expect(pending_with_lease).not_to be_valid
    expect(processing_without_lease).not_to be_valid
    expect(described_class.ready).to include(expired)
    expect(described_class.ready).not_to include(active)
    expect(described_class.expired_leases).to contain_exactly(expired)
  end
end
