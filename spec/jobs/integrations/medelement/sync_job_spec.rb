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
  end

  it 'does not let a scheduled job execute an already active manual run' do
    run

    job.perform(hook.id)

    expect(run.reload).to be_queued
    expect(coordinator).not_to have_received(:perform)
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
