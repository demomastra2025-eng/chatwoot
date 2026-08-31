require 'rails_helper'

RSpec.describe Integrations::Medelement::SyncRunLauncher do
  let(:account) { create(:account) }
  let(:hook) { create(:integrations_hook, account: account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:enqueued_job) { instance_double(Integrations::Medelement::SyncJob, successfully_enqueued?: true) }

  before do
    allow(Integrations::Medelement::SyncJob).to receive(:perform_later).and_return(enqueued_job)
  end

  it 'creates a persisted manual run before enqueueing the job' do
    allow(Integrations::Medelement::HookRuntimeLock).to receive(:acquire!).and_call_original

    run, enqueued = described_class.new(hook: hook, requested_by: admin).perform

    expect(enqueued).to be(true)
    expect(run).to have_attributes(account: account, hook: hook, requested_by: admin, trigger: 'manual', status: 'queued')
    expect(Integrations::Medelement::HookRuntimeLock).to have_received(:acquire!).with(account_id: account.id, hook_id: hook.id)
    expect(Integrations::Medelement::SyncJob).to have_received(:perform_later).with(hook.id, run.id)
  end

  it 'returns the active run instead of enqueueing duplicate work' do
    existing_run = Integrations::Medelement::SyncRun.create!(account: account, hook: hook, trigger: 'manual')

    run, enqueued = described_class.new(hook: hook, requested_by: admin).perform

    expect([run, enqueued]).to eq([existing_run, false])
    expect(Integrations::Medelement::SyncJob).not_to have_received(:perform_later)
  end

  it 'creates a phase-scoped retry run' do
    run, = described_class.new(hook: hook, requested_by: admin, phases: ['services']).perform

    expect(run).to have_attributes(trigger: 'retry', requested_phases: ['services'])
  end

  it 'rejects unsupported phases before persisting or enqueueing' do
    expect do
      described_class.new(hook: hook, requested_by: admin, phases: ['write_commands']).perform
    end.to raise_error(ArgumentError, /Unsupported Medelement sync phases/)

    expect(Integrations::Medelement::SyncRun.count).to be_zero
    expect(Integrations::Medelement::SyncJob).not_to have_received(:perform_later)
  end

  it 'fails closed when the hook was deleted before the runtime lock was acquired' do
    stale_hook = hook
    hook.delete

    expect do
      described_class.new(hook: stale_hook, requested_by: admin).perform
    end.to raise_error(ActiveRecord::RecordNotFound)

    expect(Integrations::Medelement::SyncRun.count).to be_zero
    expect(Integrations::Medelement::SyncJob).not_to have_received(:perform_later)
  end

  it 'fails the manual run when the queue adapter rejects enqueue without raising' do
    allow(enqueued_job).to receive(:successfully_enqueued?).and_return(false)

    expect do
      described_class.new(hook: hook, requested_by: admin).perform
    end.to raise_error(ActiveJob::EnqueueError, 'Failed to enqueue Medelement sync job')

    expect(Integrations::Medelement::SyncRun.where(hook: hook).sole).to be_failed
  end
end
