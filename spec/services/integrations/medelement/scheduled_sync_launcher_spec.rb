require 'rails_helper'

RSpec.describe Integrations::Medelement::ScheduledSyncLauncher do
  let(:account) { create(:account) }
  let(:hook) { create(:integrations_hook, :medelement, account: account) }
  let(:enqueued_job) { instance_double(Integrations::Medelement::SyncJob, successfully_enqueued?: true) }

  before do
    account.enable_features!('scheduling')
    allow(Integrations::Medelement::SyncJob).to receive(:perform_later).and_return(enqueued_job)
  end

  it 'creates and enqueues one durable scheduled run' do
    run, enqueued = described_class.new(hook: hook, phases: %w[receptions]).perform

    expect(enqueued).to be(true)
    expect(run).to have_attributes(trigger: 'scheduled', status: 'queued', requested_phases: %w[receptions])
    expect(Integrations::Medelement::SyncJob).to have_received(:perform_later).with(hook.id, run.id).once
  end

  it 'merges phases into a queued run without enqueueing another sync job' do
    run, = described_class.new(hook: hook, phases: %w[receptions]).perform

    merged_run, enqueued = described_class.new(hook: hook, phases: %w[specialists contacts]).perform

    expect(enqueued).to be(false)
    expect(merged_run.id).to eq(run.id)
    expect(run.reload.requested_phases).to eq(%w[specialists contacts receptions])
    expect(Integrations::Medelement::SyncJob).to have_received(:perform_later).once
  end

  it 'records phases arriving during a run and enqueues one follow-up run after completion' do
    run, = described_class.new(hook: hook, phases: %w[receptions]).perform
    run.start!

    _active_run, enqueued = described_class.new(hook: hook, phases: %w[contacts services]).perform
    expect(enqueued).to be(false)
    expect(run.reload.summary['pending_phases']).to eq(%w[services contacts])

    run.finish!
    described_class.enqueue_pending!(hook: hook, completed_run: run)

    follow_up = Integrations::Medelement::SyncRun.active.find_by!(hook_id: hook.id)
    expect(follow_up.requested_phases).to eq(%w[services contacts])
    expect(run.reload.summary).not_to have_key('pending_phases')
    expect(Integrations::Medelement::SyncJob).to have_received(:perform_later).twice
  end

  it 'creates a new run when the previously active run becomes terminal before phase merge' do
    old_run, = described_class.new(hook: hook, phases: %w[receptions]).perform
    active_scope = instance_double(ActiveRecord::Relation, find_by: old_run)
    allow(Integrations::Medelement::SyncRun).to receive(:active).and_return(active_scope)
    allow(old_run).to receive(:reload).and_wrap_original do |original, *arguments|
      reloaded = original.call(*arguments)
      unless reloaded.terminal?
        # Simulate the worker committing its terminal state after the active lookup but before the merge lock.
        # rubocop:disable Rails/SkipsModelValidations
        reloaded.update_columns(status: 'succeeded', completed_at: Time.current)
        # rubocop:enable Rails/SkipsModelValidations
      end
      original.call(*arguments)
    end

    new_run, enqueued = described_class.new(hook: hook, phases: %w[contacts]).perform

    expect(enqueued).to be(true)
    expect(new_run).to be_queued
    expect(new_run.id).not_to eq(old_run.id)
    expect(new_run.requested_phases).to eq(%w[contacts])
  end

  it 'rejects unsupported phases before touching the queue' do
    expect do
      described_class.new(hook: hook, phases: %w[unknown]).perform
    end.to raise_error(ArgumentError, /Unsupported Medelement sync phases/)

    expect(Integrations::Medelement::SyncJob).not_to have_received(:perform_later)
  end

  it 'fails the durable run when the queue adapter rejects enqueue without raising' do
    allow(enqueued_job).to receive(:successfully_enqueued?).and_return(false)

    expect do
      described_class.new(hook: hook, phases: %w[receptions]).perform
    end.to raise_error(ActiveJob::EnqueueError, 'Failed to enqueue scheduled Medelement sync job')

    expect(Integrations::Medelement::SyncRun.where(hook: hook).sole).to be_failed
  end
end
