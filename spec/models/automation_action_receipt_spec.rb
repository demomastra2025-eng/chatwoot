require 'rails_helper'

RSpec.describe AutomationActionReceipt do
  it 'uses a stable legacy action identity from the execution snapshot' do
    execution = create(:automation_execution, actions_snapshot: [{ 'action_name' => 'assign_team' }])
    receipt = build(:automation_action_receipt, automation_execution: execution, account: execution.account, action_id: nil)

    expect(receipt).to be_valid
    expect(receipt.action_id).to eq('legacy-index:0')
  end

  it 'preserves an explicit action identity' do
    execution = create(:automation_execution, actions_snapshot: [{ 'action_id' => 'action-123' }])
    receipt = build(:automation_action_receipt, automation_execution: execution, account: execution.account, action_id: nil)

    receipt.validate
    expect(receipt.action_id).to eq('action-123')
  end

  it 'rejects cross-account executions and positions absent from the snapshot' do
    execution = create(:automation_execution, actions_snapshot: [{ 'action_name' => 'assign_team' }])
    receipt = build(
      :automation_action_receipt,
      account: create(:account),
      automation_execution: execution,
      position: 1,
      action_signature: 'signature'
    )

    expect(receipt).not_to be_valid
    expect(receipt.errors[:automation_execution]).to be_present
    expect(receipt.errors[:position]).to be_present
  end

  it 'keeps persisted action identity immutable' do
    receipt = create(:automation_action_receipt)

    receipt.action_id = 'replacement'
    expect(receipt).not_to be_valid
    expect(receipt.errors[:base]).to include(/action_id/)
  end

  it 'rejects caller identities and signatures that differ from the execution snapshot' do
    execution = create(:automation_execution, actions_snapshot: [{ 'action_id' => 'expected', 'action_name' => 'assign_team' }])
    receipt = build(
      :automation_action_receipt,
      automation_execution: execution,
      account: execution.account,
      action_id: 'forged',
      action_signature: 'forged'
    )

    expect(receipt).not_to be_valid
    expect(receipt.errors[:action_id]).to be_present
    expect(receipt.errors[:action_signature]).to be_present
  end

  it 'requires status-coherent leases and recovers expired processing rows' do
    pending_with_lease = build(:automation_action_receipt, lease_owner: 'worker-1', lease_expires_at: 1.minute.from_now)
    processing_without_lease = build(:automation_action_receipt, status: 'processing')
    expired = create(:automation_action_receipt, status: 'processing', lease_owner: 'dead-worker', lease_expires_at: 1.minute.ago)
    active = create(:automation_action_receipt, status: 'processing', lease_owner: 'live-worker', lease_expires_at: 1.minute.from_now)

    expect(pending_with_lease).not_to be_valid
    expect(processing_without_lease).not_to be_valid
    expect(described_class.ready).to include(expired)
    expect(described_class.ready).not_to include(active)
    expect(described_class.expired_leases).to contain_exactly(expired)
  end
end
