require 'rails_helper'
require 'erb'

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
    allow(job).to receive(:with_lock).and_yield(-> { true })
    allow(Integrations::Medelement::SyncCoordinatorService).to receive(:new).with(hook: hook).and_return(coordinator)
    allow(coordinator).to receive(:perform) do |sync_run:, phases:|
      phases.each { |phase| sync_run.complete_phase!(phase, imported_count: 1, skipped_count: 0) }
      sync_run.finish!
    end
  end

  describe 'Sidekiq queue isolation' do
    def rendered_config(path)
      YAML.safe_load(
        ERB.new(Rails.root.join(path).read).result,
        permitted_classes: [Symbol],
        aliases: true
      )
    end

    it 'routes provider reads and cleanup to the isolated sync queue' do
      jobs = [
        described_class,
        Integrations::Medelement::PatientEnrichmentJob,
        Integrations::Medelement::CleanupJob,
        Integrations::Medelement::DispatchJob
      ]

      expect(jobs.map(&:queue_name).uniq).to eq(['medelement_sync'])
    end

    it 'routes provider writes and their dispatcher to the isolated commands queue' do
      jobs = [
        Integrations::Medelement::ProviderCommandDispatcherJob,
        Integrations::Medelement::ProviderCommandJob,
        Integrations::Medelement::ProviderCommandConfirmationJob,
        Integrations::Medelement::ProviderCommandReconciliationJob,
        Integrations::Medelement::OutboundChangeJob
      ]

      expect(jobs.map(&:queue_name).uniq).to eq(['medelement_provider_commands'])
    end

    it 'serves each MedElement queue from a dedicated worker only' do
      with_modified_env(
        MEDELEMENT_SYNC_SIDEKIQ_CONCURRENCY: nil,
        MEDELEMENT_COMMANDS_SIDEKIQ_CONCURRENCY: nil
      ) do
        sync_config = rendered_config('config/sidekiq_medelement_sync.yml')
        commands_config = rendered_config('config/sidekiq_medelement_commands.yml')
        shared_config = rendered_config('config/sidekiq.yml')

        expect(sync_config[:queues]).to eq(['medelement_sync'])
        expect(sync_config[:concurrency]).to eq(1)
        expect(commands_config[:queues]).to eq(['medelement_provider_commands'])
        expect(commands_config[:concurrency]).to eq(2)
        expect(shared_config[:queues]).not_to include('medelement_sync', 'medelement_provider_commands')
      end
    end
  end

  it 'reroutes jobs serialized on the legacy shared queue without running provider work' do
    legacy_job = described_class.new
    legacy_job.queue_name = 'medium'
    configured_job = instance_double(ActiveJob::ConfiguredJob)
    rerouted_job = instance_double(described_class, successfully_enqueued?: true)
    allow(described_class).to receive(:set).with(queue: 'medelement_sync').and_return(configured_job)
    allow(configured_job).to receive(:perform_later).and_return(rerouted_job)

    legacy_job.perform(hook.id, run.id, ['services'])

    expect(configured_job).to have_received(:perform_later).with(hook.id, run.id, ['services'])
    expect(coordinator).not_to have_received(:perform)
  end

  it 'raises when a legacy queue reroute cannot be enqueued' do
    legacy_job = described_class.new
    legacy_job.queue_name = 'medium'
    configured_job = instance_double(ActiveJob::ConfiguredJob)
    allow(described_class).to receive(:set).with(queue: 'medelement_sync').and_return(configured_job)
    rerouted_job = instance_double(described_class, successfully_enqueued?: false)
    allow(configured_job).to receive(:perform_later).and_return(rerouted_job)

    expect { legacy_job.perform(hook.id, run.id, ['services']) }
      .to raise_error(ActiveJob::EnqueueError, 'Failed to reroute legacy Medelement sync job')
    expect(coordinator).not_to have_received(:perform)
  end

  it 'executes and completes the exact persisted run passed by the launcher' do
    job.perform(hook.id, run.id)

    expect(run.reload).to be_succeeded
    expect(run.phase_results.dig('services', 'imported_count')).to eq(1)
    expect(coordinator).to have_received(:perform).with(sync_run: run, phases: ['services'])
    expect(job).to have_received(:with_lock).with(
      format(Redis::Alfred::MEDELEMENT_SYNC_MUTEX, account_id: account.id),
      30.minutes
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

  it 'retries the durable run after losing the owner lock lease' do
    error = Integrations::Medelement::SyncRunHeartbeat::LockLeaseLostError.new('lease lost')
    allow(coordinator).to receive(:perform).and_raise(error)

    expect do
      described_class.perform_now(hook.id, run.id)
    end.to have_enqueued_job(described_class).with(hook.id, run.id)

    expect(run.reload).to have_attributes(status: 'retrying', completed_at: nil)
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

  it 'uses bounded exponential jitter for the provider API fallback retries' do
    allow(Kernel).to receive(:rand, &:end)

    waits = (1..7).map { |executions| described_class::API_RETRY_WAIT.call(executions) }

    expect(waits).to eq([30.0, 60.0, 120.0, 240.0, 300.0, 300.0, 300.0])
    expect(job.send(:retry_attempts_for, Integrations::Medelement::Client::ApiError.new('failed'))).to eq(6)
  end

  it 'tracks provider retries independently from prior lock retries' do
    error = Integrations::Medelement::Client::ApiError.new('Provider request failed', status: 429)
    retry_job = described_class.new(hook.id, run.id)
    retry_job.executions = 6
    retry_job.exception_executions = {
      [MutexApplicationJob::LockAcquisitionError].to_s => 1,
      [Integrations::Medelement::Client::ApiError].to_s => 4
    }
    allow(retry_job).to receive(:with_lock).and_yield(-> { true })
    allow(coordinator).to receive(:perform).and_raise(error)

    expect { retry_job.perform_now }.to have_enqueued_job(described_class).with(hook.id, run.id)

    expect(run.reload).to have_attributes(status: 'retrying', completed_at: nil)
  end

  it 'fails the run only when the provider retry handler is exhausted' do
    error = Integrations::Medelement::Client::ApiError.new('Provider request failed', status: 429)
    retry_job = described_class.new(hook.id, run.id)
    retry_job.executions = 6
    retry_job.exception_executions = { [Integrations::Medelement::Client::ApiError].to_s => 5 }
    allow(retry_job).to receive(:with_lock).and_yield(-> { true })
    allow(coordinator).to receive(:perform).and_raise(error)

    expect { retry_job.perform_now }.to raise_error(error)

    expect(run.reload).to be_failed
  end
end
