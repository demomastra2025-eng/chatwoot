require 'rails_helper'
require 'sidekiq/api'

RSpec.describe Integrations::Medelement::StaleSyncRunRecoveryJob do
  let(:account) { create(:account) }
  let(:hook) { create(:integrations_hook, :medelement, account: account) }
  let(:queued_jobs) { [] }
  let(:scheduled_jobs) { [] }
  let(:retry_jobs) { [] }
  let(:working_jobs) { [] }

  before do
    account.enable_features!('scheduling')
    enqueued_job = instance_double(Integrations::Medelement::SyncJob, successfully_enqueued?: true)
    allow(Integrations::Medelement::SyncJob).to receive(:perform_later).and_return(enqueued_job)
    allow(Sidekiq::Queue).to receive(:all).and_return([queued_jobs])
    allow(Sidekiq::ScheduledSet).to receive(:new).and_return(instance_double(Sidekiq::ScheduledSet, scan: scheduled_jobs))
    allow(Sidekiq::RetrySet).to receive(:new).and_return(instance_double(Sidekiq::RetrySet, scan: retry_jobs))
    allow(Sidekiq::WorkSet).to receive(:new).and_return(working_jobs)
    allow(Sidekiq::ProcessSet).to receive(:[]).and_return(nil)
  end

  after do
    Redis::Alfred.delete(format(Redis::Alfred::MEDELEMENT_SYNC_MUTEX, account_id: account.id))
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

    described_class.new.send(:recover, run)

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

  def orphaned_run(heartbeat_at: 15.minutes.ago)
    Integrations::Medelement::SyncRun.create!(
      account: account,
      hook: hook,
      trigger: 'scheduled',
      status: 'running',
      requested_phases: %w[specialists schedules],
      created_at: 20.minutes.ago,
      summary: {
        'worker' => {
          'job_id' => 'active-job-id', 'provider_job_id' => 'sidekiq-jid',
          'process_id' => 'retired-worker-process', 'token' => 'retired-worker-token',
          'heartbeat_at' => heartbeat_at.iso8601(6)
        }
      }
    )
  end

  def job_record(run)
    Sidekiq::JobRecord.new(
      'class' => 'ActiveJob::QueueAdapters::SidekiqAdapter::JobWrapper',
      'wrapped' => 'Integrations::Medelement::SyncJob',
      'args' => [{ 'job_class' => 'Integrations::Medelement::SyncJob', 'arguments' => [hook.id, run.id] }]
    )
  end

  it 'recovers an identified orphan after two missing heartbeats even when its row was recently updated' do
    run = orphaned_run
    run.update!(phase_results: { 'specialists' => { 'status' => 'succeeded' } },
                summary: run.summary.merge('pending_phases' => %w[contacts]))

    described_class.perform_now

    expect(run.reload).to be_failed
    continuation = Integrations::Medelement::SyncRun.active.find_by!(hook_id: hook.id)
    expect(continuation.requested_phases).to eq(%w[schedules contacts])
    expect(Integrations::Medelement::SyncJob).to have_received(:perform_later).with(hook.id, continuation.id).once
  end

  it 'keeps a known owner protected until two heartbeat intervals have passed' do
    run = orphaned_run(heartbeat_at: 8.minutes.ago)

    described_class.perform_now

    expect(run.reload).to be_running
    expect(Integrations::Medelement::SyncJob).not_to have_received(:perform_later)
  end

  it 'keeps the 45 minute fallback when the execution identity is incomplete' do
    run = orphaned_run
    run.update!(summary: { 'worker' => { 'heartbeat_at' => 15.minutes.ago.iso8601(6) } })

    described_class.perform_now

    expect(run.reload).to be_running
    expect(Integrations::Medelement::SyncJob).not_to have_received(:perform_later)
  end

  it 'leaves a stale heartbeat alone while its owning Sidekiq process is still registered' do
    run = orphaned_run(heartbeat_at: 1.hour.ago)
    allow(Sidekiq::ProcessSet).to receive(:[]).with('retired-worker-process').and_return(instance_double(Sidekiq::Process))

    described_class.perform_now

    expect(run.reload).to be_running
    expect(Integrations::Medelement::SyncJob).not_to have_received(:perform_later)
  end

  %w[queued scheduled retry working].each do |location|
    it "leaves a stale run alone when its sync job is #{location}" do
      run = orphaned_run(heartbeat_at: 1.hour.ago)
      entry = job_record(run)
      case location
      when 'queued' then queued_jobs << entry
      when 'scheduled' then scheduled_jobs << entry
      when 'retry' then retry_jobs << entry
      when 'working' then working_jobs << ['worker-process', 'thread-id', instance_double(Sidekiq::Work, job: entry)]
      end

      described_class.perform_now

      expect(run.reload).to be_running
      expect(Integrations::Medelement::SyncJob).not_to have_received(:perform_later)
    end
  end

  it 'does not release an existing account mutex or recover its run' do
    run = orphaned_run(heartbeat_at: 1.hour.ago)
    lock_key = format(Redis::Alfred::MEDELEMENT_SYNC_MUTEX, account_id: account.id)
    Redis::Alfred.set(lock_key, 'live-worker-token', ex: 30.minutes)

    described_class.perform_now

    expect(run.reload).to be_running
    expect(Redis::Alfred.get(lock_key)).to eq('live-worker-token')
    expect(Integrations::Medelement::SyncJob).not_to have_received(:perform_later)
  end

  it 'rechecks its lock token and preserves a successor mutex before failing a run' do
    run = orphaned_run
    lock_key = format(Redis::Alfred::MEDELEMENT_SYNC_MUTEX, account_id: account.id)
    checks = 0
    allow(Sidekiq::Queue).to receive(:all) do
      checks += 1
      Redis::Alfred.set(lock_key, 'successor-token', ex: 30.minutes) if checks == 2
      [queued_jobs]
    end

    described_class.perform_now

    expect(run.reload).to be_running
    expect(Redis::Alfred.get(lock_key)).to eq('successor-token')
    expect(Integrations::Medelement::SyncJob).not_to have_received(:perform_later)
  end

  it 'rechecks a heartbeat committed between candidate selection and the recovery claim' do
    run = orphaned_run
    allow(Sidekiq::Queue).to receive(:all) do
      run.heartbeat!(worker_token: 'retired-worker-token')
      [queued_jobs]
    end

    described_class.perform_now

    expect(run.reload).to be_running
    expect(Integrations::Medelement::SyncJob).not_to have_received(:perform_later)
  end

  it 'leaves the durable run active when Sidekiq presence cannot be checked' do
    run = orphaned_run
    allow(Sidekiq::Queue).to receive(:all).and_raise(RedisClient::ConnectionError, 'Redis unavailable')

    expect { described_class.perform_now }.to raise_error(RedisClient::ConnectionError)

    expect(run.reload).to be_running
    expect(Integrations::Medelement::SyncJob).not_to have_received(:perform_later)
    expect(Redis::Alfred.get(format(Redis::Alfred::MEDELEMENT_SYNC_MUTEX, account_id: account.id))).to be_nil
  end
end
