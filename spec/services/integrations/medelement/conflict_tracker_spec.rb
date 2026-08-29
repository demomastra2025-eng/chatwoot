require 'rails_helper'

RSpec.describe Integrations::Medelement::ConflictTracker do
  let(:account) { create(:account) }
  let(:hook) { create(:integrations_hook, account: account) }
  let(:first_run) do
    Integrations::Medelement::SyncRun.create!(
      account: account,
      hook: hook,
      trigger: 'manual',
      status: 'running'
    )
  end

  it 'stores a stable fingerprint without exposing provider identity or contact data' do
    described_class.new(sync_run: first_run).record!(
      phase: 'contacts',
      entity_type: 'contact',
      conflict_type: 'phone_mismatch',
      entity_key: 'patient-123456789012',
      details: { phone: '+7 777 123 45 67', reason: 'Mismatch for 123456789012' }
    )

    conflict = Integrations::Medelement::SyncConflict.last
    serialized = conflict.attributes.to_json
    expect(serialized).not_to include('patient-123456789012', '+7 777 123 45 67')
    expect(conflict.entity_key_digest).to match(/\A[0-9a-f]{64}\z/)
    expect(conflict.details.values).to all(satisfy { |value| value.exclude?('123456789012') })
  end

  it 'increments an existing conflict and reopens it after it was resolved' do
    tracker = described_class.new(sync_run: first_run)
    tracker.record!(
      phase: 'services', entity_type: 'service', conflict_type: 'invalid_service', entity_key: 'service-1'
    )
    conflict = Integrations::Medelement::SyncConflict.last
    conflict.resolve_automatically!
    first_run.update!(status: 'succeeded')
    second_run = Integrations::Medelement::SyncRun.create!(account: account, hook: hook, trigger: 'manual', status: 'running')

    described_class.new(sync_run: second_run).record!(
      phase: 'services', entity_type: 'service', conflict_type: 'invalid_service', entity_key: 'service-1'
    )

    expect(conflict.reload).to have_attributes(status: 'open', occurrences: 2, last_sync_run_id: second_run.id)
  end

  it 'automatically resolves open conflicts absent from a successful repeated phase' do
    first_tracker = described_class.new(sync_run: first_run)
    first_tracker.record!(
      phase: 'receptions', entity_type: 'reception', conflict_type: 'invalid_reception', entity_key: 'reception-1'
    )
    conflict = Integrations::Medelement::SyncConflict.last
    first_run.update!(status: 'succeeded')
    second_run = Integrations::Medelement::SyncRun.create!(account: account, hook: hook, trigger: 'retry', status: 'running')

    described_class.new(sync_run: second_run).resolve_absent!('receptions')

    expect(conflict.reload).to be_resolved
    expect(conflict.resolution_note).to include('successful sync phase')
  end

  it 'resolves only conflicts belonging to processed entity keys for a bounded phase' do
    tracker = described_class.new(sync_run: first_run)
    tracker.record!(phase: 'contacts', entity_type: 'contact', conflict_type: 'phone_mismatch', entity_key: 'patient-1')
    tracker.record!(phase: 'contacts', entity_type: 'contact', conflict_type: 'phone_mismatch', entity_key: 'patient-2')
    first_run.update!(status: 'succeeded')
    second_run = Integrations::Medelement::SyncRun.create!(account: account, hook: hook, trigger: 'retry', status: 'running')

    described_class.new(sync_run: second_run).resolve_absent!('contacts', entity_keys: ['patient-1'])

    conflicts = Integrations::Medelement::SyncConflict.order(:id)
    expect(conflicts.first).to be_resolved
    expect(conflicts.second).to be_open
  end

  it 'preserves an administrator ignore decision when the conflict repeats' do
    tracker = described_class.new(sync_run: first_run)
    tracker.record!(
      phase: 'services', entity_type: 'service', conflict_type: 'invalid_service', entity_key: 'service-2'
    )
    conflict = Integrations::Medelement::SyncConflict.last
    conflict.ignore!(user: create(:user, account: account, role: :administrator))
    first_run.update!(status: 'succeeded')
    second_run = Integrations::Medelement::SyncRun.create!(account: account, hook: hook, trigger: 'retry', status: 'running')

    described_class.new(sync_run: second_run).record!(
      phase: 'services', entity_type: 'service', conflict_type: 'invalid_service', entity_key: 'service-2'
    )

    expect(conflict.reload).to have_attributes(status: 'ignored', occurrences: 2)
  end

  it 'keeps identical provider conflicts isolated between hooks in the same account' do
    other_hook = create(:integrations_hook, account: account, app_id: 'webhook')
    other_run = Integrations::Medelement::SyncRun.create!(
      account: account,
      hook: other_hook,
      trigger: 'manual',
      status: 'running'
    )
    attributes = {
      phase: 'services',
      entity_type: 'service',
      conflict_type: 'invalid_service',
      entity_key: 'shared-provider-code'
    }

    described_class.new(sync_run: first_run).record!(**attributes)
    described_class.new(sync_run: other_run).record!(**attributes)

    conflicts = Integrations::Medelement::SyncConflict.where(account: account).order(:hook_id)
    expect(conflicts.size).to eq(2)
    expect(conflicts.map(&:fingerprint).uniq.size).to eq(2)
  end
end
