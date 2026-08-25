require 'rails_helper'

RSpec.describe Integrations::Medelement::SyncJob, type: :job do
  let(:account) { create(:account) }
  let(:hook) { create(:integrations_hook, account: account) }
  let(:run) do
    Integrations::Medelement::SyncRun.create!(
      account: account,
      hook: hook,
      trigger: 'manual',
      requested_phases: ['services']
    )
  end
  let(:coordinator) { instance_double(Integrations::Medelement::SyncCoordinatorService) }
  let(:job) { described_class.new }

  before do
    allow(job).to receive(:with_lock).and_yield
    allow(Integrations::Medelement::SyncCoordinatorService).to receive(:new).with(hook: hook).and_return(coordinator)
    allow(coordinator).to receive(:perform) do |sync_run:, phases:|
      phases.each { |phase| sync_run.complete_phase!(phase, imported_count: 1, skipped_count: 0) }
      sync_run.finish!
    end
  end

  it 'executes and completes the exact persisted run passed by the launcher' do
    job.perform(hook.id, run.id)

    expect(run.reload).to be_succeeded
    expect(run.phase_results.dig('services', 'imported_count')).to eq(1)
    expect(coordinator).to have_received(:perform).with(sync_run: run, phases: ['services'])
    expect(job).to have_received(:with_lock).with(
      format(Redis::Alfred::MEDELEMENT_SYNC_MUTEX, account_id: account.id),
      2.hours
    )
  end

  it 'retries uncovered scheduled phases when another sync run is active' do
    run

    expect do
      job.perform(hook.id, nil, %w[specialists contacts receptions])
    end.to raise_error(described_class::ScheduledSyncBusyError)

    expect(run.reload).to be_queued
    expect(coordinator).not_to have_received(:perform)
  end

  it 'coalesces scheduled phases already covered by the active run' do
    run

    job.perform(hook.id, nil, ['services'])

    expect(run.reload).to be_queued
    expect(coordinator).not_to have_received(:perform)
  end

  it 'resumes a retrying scheduled run instead of coalescing its retry away' do
    scheduled_run = Integrations::Medelement::SyncRun.create!(
      account: account,
      hook: hook,
      trigger: 'scheduled',
      status: 'retrying',
      requested_phases: ['services'],
      phase_results: { 'services' => { 'status' => 'failed' } }
    )

    job.perform(hook.id, nil, ['services'])

    expect(scheduled_run.reload).to be_succeeded
    expect(coordinator).to have_received(:perform).with(sync_run: scheduled_run, phases: ['services'])
  end

  it 'keeps a failing run active until the job chooses its retry state' do
    error = Integrations::Medelement::Client::ApiError.new('Provider request failed')
    allow(coordinator).to receive(:perform) do |sync_run:, **|
      sync_run.start_phase!('services')
      sync_run.record_phase_failure!('services', error)

      expect(job.send(:create_scheduled_sync_run, hook, ['services'])).to be_nil
      raise error
    end

    expect do
      described_class.perform_now(hook.id, run.id)
    end.to have_enqueued_job(described_class).with(hook.id, run.id)

    expect(run.reload).to have_attributes(status: 'retrying', completed_at: nil)
    expect(Integrations::Medelement::SyncRun.where(hook: hook)).to contain_exactly(run)
  end

  it 'preserves scheduled phases when ActiveJob retries a collision' do
    run
    phases = %w[specialists contacts receptions]

    expect do
      described_class.perform_now(hook.id, nil, phases)
    end.to have_enqueued_job(described_class).with(hook.id, nil, phases)
  end

  it 'persists and executes only the phases assigned to an entity schedule' do
    job.perform(hook.id, nil, %w[specialists contacts receptions])

    scheduled_run = Integrations::Medelement::SyncRun.where(hook: hook, trigger: 'scheduled').sole
    expect(scheduled_run.requested_phases).to eq(%w[specialists contacts receptions])
    expect(coordinator).to have_received(:perform).with(
      sync_run: scheduled_run,
      phases: %w[specialists contacts receptions]
    )
  end

  it 'does not replay a persisted run that already reached a terminal state' do
    run.update!(status: 'succeeded', completed_at: Time.current)

    job.perform(hook.id, run.id)

    expect(run.reload).to be_succeeded
    expect(coordinator).not_to have_received(:perform)
  end

  it 'resumes at the failed phase without replaying successful phases' do
    completed_at = 5.minutes.ago.iso8601
    run.update!(
      status: 'retrying',
      requested_phases: %w[services contacts],
      phase_results: {
        'services' => { 'status' => 'succeeded', 'completed_at' => completed_at },
        'contacts' => { 'status' => 'failed', 'completed_at' => 1.minute.ago.iso8601 }
      }
    )

    job.perform(hook.id, run.id)

    expect(coordinator).to have_received(:perform).with(sync_run: run, phases: ['contacts'])
    expect(run.reload.phase_results.dig('services', 'completed_at')).to eq(completed_at)
    expect(run.phase_results.dig('contacts', 'status')).to eq('succeeded')
  end

  it 'finishes without replay when all persisted phases already succeeded' do
    run.update!(
      status: 'retrying',
      phase_results: { 'services' => { 'status' => 'succeeded', 'completed_at' => 1.minute.ago.iso8601 } }
    )

    job.perform(hook.id, run.id)

    expect(coordinator).to have_received(:perform).with(sync_run: run, phases: [])
    expect(run.reload).to be_succeeded
  end
end
