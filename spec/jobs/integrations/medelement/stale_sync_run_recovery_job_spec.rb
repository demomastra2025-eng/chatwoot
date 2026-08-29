require 'rails_helper'

RSpec.describe Integrations::Medelement::StaleSyncRunRecoveryJob do
  let(:account) { create(:account) }
  let(:hook) { create(:integrations_hook, :medelement, account: account) }

  before do
    account.enable_features!('scheduling')
    enqueued_job = instance_double(Integrations::Medelement::SyncJob, successfully_enqueued?: true)
    allow(Integrations::Medelement::SyncJob).to receive(:perform_later).and_return(enqueued_job)
  end

  it 'fails an orphaned active run and launches one continuation with unfinished and pending phases' do
    stale_run = Integrations::Medelement::SyncRun.create!(
      account: account,
      hook: hook,
      trigger: 'scheduled',
      status: 'running',
      requested_phases: %w[receptions],
      summary: { 'pending_phases' => %w[contacts] }
    )
    stale_run.update!(updated_at: 1.hour.ago)

    described_class.perform_now

    expect(stale_run.reload.status).to eq('failed')
    expect(stale_run.error_code).to end_with('stale_sync_run_recovery_job.stale_run_error')
    continuation = Integrations::Medelement::SyncRun.active.find_by!(hook_id: hook.id)
    expect(continuation.requested_phases).to eq(%w[contacts receptions])
    expect(Integrations::Medelement::SyncJob).to have_received(:perform_later).with(hook.id, continuation.id).once
  end

  it 'preserves continuation phases when enqueue fails and retries recovery' do
    stale_run = Integrations::Medelement::SyncRun.create!(
      account: account,
      hook: hook,
      trigger: 'scheduled',
      status: 'running',
      requested_phases: %w[receptions],
      summary: { 'pending_phases' => %w[contacts] }
    )
    stale_run.update!(updated_at: 1.hour.ago)
    failed_job = instance_double(Integrations::Medelement::SyncJob, successfully_enqueued?: false)
    allow(Integrations::Medelement::SyncJob).to receive(:perform_later).and_return(failed_job)

    expect { described_class.perform_now }.to have_enqueued_job(described_class)

    continuation = Integrations::Medelement::SyncRun.active.find_by!(hook_id: hook.id)
    expect(continuation.requested_phases).to eq(%w[contacts receptions])
    expect(continuation.updated_at).to be < described_class::STALE_AFTER.ago
  end

  it 'leaves a recent active run untouched' do
    run = Integrations::Medelement::SyncRun.create!(
      account: account,
      hook: hook,
      trigger: 'scheduled',
      status: 'running',
      requested_phases: %w[receptions]
    )

    described_class.perform_now

    expect(run.reload).to be_running
    expect(Integrations::Medelement::SyncJob).not_to have_received(:perform_later)
  end

  it 'fails a stale run without continuation when the hook is disabled' do
    hook.update!(status: 'disabled')
    run = Integrations::Medelement::SyncRun.create!(
      account: account,
      hook: hook,
      trigger: 'scheduled',
      status: 'running',
      requested_phases: %w[receptions]
    )
    run.update!(updated_at: 1.hour.ago)

    described_class.perform_now

    expect(run.reload).to be_failed
    expect(Integrations::Medelement::SyncJob).not_to have_received(:perform_later)
  end

  it 'does not fail an unavailable-hook candidate that completed after selection' do
    hook.update!(status: 'disabled')
    run = Integrations::Medelement::SyncRun.create!(
      account: account,
      hook: hook,
      trigger: 'scheduled',
      status: 'running',
      requested_phases: %w[receptions]
    )
    run.update!(updated_at: 1.hour.ago)
    run.finish!

    described_class.new.send(:fail_unavailable!, run)

    expect(run.reload).to be_succeeded
  end

  it 'leaves a stale-looking run untouched after its worker heartbeat' do
    run = Integrations::Medelement::SyncRun.create!(
      account: account,
      hook: hook,
      trigger: 'scheduled',
      status: 'running',
      requested_phases: %w[receptions]
    )
    run.update!(updated_at: 1.hour.ago)

    run.heartbeat!
    described_class.perform_now

    expect(run.reload).to be_running
    expect(Integrations::Medelement::SyncJob).not_to have_received(:perform_later)
  end

  it 'prevents a recovered worker from overwriting the terminal state' do
    run = Integrations::Medelement::SyncRun.create!(
      account: account,
      hook: hook,
      trigger: 'scheduled',
      status: 'running',
      current_phase: 'receptions',
      requested_phases: %w[receptions]
    )
    run.update!(updated_at: 1.hour.ago)

    described_class.perform_now

    expect { run.complete_phase!('receptions', imported_count: 1) }
      .to raise_error(Integrations::Medelement::SyncRun::InactiveRunError)
    run.finish!
    expect(run.reload).to be_failed
  end
end
