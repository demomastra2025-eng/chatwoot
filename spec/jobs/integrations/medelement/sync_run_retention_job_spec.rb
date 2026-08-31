require 'rails_helper'

RSpec.describe Integrations::Medelement::SyncRunRetentionJob do
  let(:account) { create(:account).tap { |record| record.enable_features!('scheduling') } }
  let(:hook) { create(:integrations_hook, :medelement, account: account) }

  before do
    schedule_service = instance_double(Integrations::Medelement::CronScheduleService, sync!: true)
    allow(Integrations::Medelement::CronScheduleService).to receive(:new).and_return(schedule_service)
  end

  it 'prunes old terminal history while preserving active, latest and actionable-conflict runs' do
    deletable = create_run(status: 'succeeded', completed_at: 105.days.ago)
    resolved_reference = create_run(status: 'failed', completed_at: 104.days.ago)
    actionable_reference = create_run(status: 'partial', completed_at: 103.days.ago)
    active = create_run(status: 'queued', completed_at: nil, created_at: 100.days.ago)
    latest = create_run(status: 'succeeded', completed_at: 1.day.ago)
    resolved_conflict = create_conflict(status: 'resolved', run: resolved_reference, suffix: 'resolved')
    actionable_conflict = create_conflict(status: 'open', run: actionable_reference, suffix: 'open')

    described_class.perform_now

    expect(Integrations::Medelement::SyncRun.where(id: [deletable.id, resolved_reference.id])).to be_empty
    expect(Integrations::Medelement::SyncRun.where(id: [actionable_reference.id, active.id, latest.id]).count).to eq(3)
    expect(resolved_conflict.reload).to have_attributes(first_sync_run_id: nil, last_sync_run_id: nil)
    expect(actionable_conflict.reload).to have_attributes(
      first_sync_run_id: actionable_reference.id,
      last_sync_run_id: actionable_reference.id
    )
  end

  def create_run(status:, completed_at:, created_at: completed_at || Time.current)
    Integrations::Medelement::SyncRun.create!(
      account: account,
      hook: hook,
      trigger: 'scheduled',
      status: status,
      requested_phases: ['receptions'],
      completed_at: completed_at,
      created_at: created_at
    )
  end

  def create_conflict(status:, run:, suffix:)
    Integrations::Medelement::SyncConflict.create!(
      account: account,
      hook: hook,
      first_sync_run: run,
      last_sync_run: run,
      phase: 'receptions',
      entity_type: 'reception',
      conflict_type: 'test_conflict',
      fingerprint: "fingerprint-#{suffix}",
      entity_key_digest: "digest-#{suffix}",
      status: status,
      first_seen_at: run.created_at,
      last_seen_at: run.created_at
    )
  end
end
