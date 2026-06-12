require 'rails_helper'

RSpec.describe Telephony::ProvisioningRun do
  it 'sanitizes secret-like values before persisting snapshots and errors' do
    run = described_class.create!(
      account: create(:account),
      operation: 'create',
      status: 'failed',
      remote_commit: true,
      idempotency_key: 'idem-1',
      desired_snapshot: {
        'connection' => {
          'username' => 'trunk-user',
          'password' => 'do-not-store-this'
        }
      },
      planned_operations: [
        {
          'key' => 'upsert_credentials',
          'payload_preview' => { 'secret' => 'do-not-store-secret' }
        }
      ],
      error_details: { 'api_token' => 'do-not-store-token' }
    )

    serialized = run.reload.attributes.slice(
      'desired_snapshot',
      'planned_operations',
      'error_details'
    ).to_json

    expect(serialized).not_to include('do-not-store-this')
    expect(serialized).not_to include('do-not-store-secret')
    expect(serialized).not_to include('do-not-store-token')
    expect(run.desired_snapshot.dig('connection', 'password')).to eq('[REDACTED]')
    expect(run.error_details['api_token']).to eq('[REDACTED]')
  end

  it 'requires known operation and status values' do
    run = described_class.new(account: create(:account), operation: 'raw_fonoster_edit', status: 'mystery')

    expect(run).not_to be_valid
    expect(run.errors[:operation]).to be_present
    expect(run.errors[:status]).to be_present
  end

  it 'uses unique audit keys but stable remote idempotency keys for the same desired state' do
    account = create(:account)
    state = {
      account_id: account.id,
      inbox_id: 123,
      refs: { number_ref: 'number-ref' },
      phone_numbers: { fonoster_tel_url: 'tel:056124100014' }
    }

    first_audit_key = described_class.idempotency_key_for(operation: 'provision', desired_state: state)
    second_audit_key = described_class.idempotency_key_for(operation: 'provision', desired_state: state)
    first_remote_key = described_class.remote_idempotency_key_for(operation: 'provision', desired_state: state)
    second_remote_key = described_class.remote_idempotency_key_for(
      operation: 'provision',
      desired_state: state.deep_stringify_keys
    )

    expect(first_audit_key).not_to eq(second_audit_key)
    expect(first_remote_key).to eq(second_remote_key)
  end
end
