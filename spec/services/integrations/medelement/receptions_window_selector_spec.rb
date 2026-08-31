require 'rails_helper'

RSpec.describe Integrations::Medelement::ReceptionsWindowSelector do
  let(:account) { create(:account).tap { |record| record.enable_features!('scheduling') } }
  let(:hook) { create(:integrations_hook, :medelement, account: account) }

  before do
    schedule_service = instance_double(Integrations::Medelement::CronScheduleService, sync!: true)
    allow(Integrations::Medelement::CronScheduleService).to receive(:new).and_return(schedule_service)
  end

  it 'uses a full window for manual runs' do
    run = build_run(trigger: 'manual')

    expect(described_class.new(hook: hook, sync_run: run).call).to eq(:full)
  end

  it 'uses a realtime window after a recent successful full audit' do
    create_full_audit(completed_at: 1.hour.ago)
    run = build_run(trigger: 'scheduled')

    expect(described_class.new(hook: hook, sync_run: run).call).to eq(:realtime)
  end

  it 'accepts a partial run when its receptions phase completed successfully' do
    create_full_audit(completed_at: 1.hour.ago, status: 'partial')
    run = build_run(trigger: 'scheduled')

    expect(described_class.new(hook: hook, sync_run: run).call).to eq(:realtime)
  end

  it 'uses a full window when the last successful full audit is stale' do
    create_full_audit(completed_at: 25.hours.ago)
    run = build_run(trigger: 'scheduled')

    expect(described_class.new(hook: hook, sync_run: run).call).to eq(:full)
  end

  it 'does not accept a failed full phase as a completed audit' do
    create_full_audit(completed_at: 1.hour.ago, phase_status: 'failed', status: 'failed')
    run = build_run(trigger: 'scheduled')

    expect(described_class.new(hook: hook, sync_run: run).call).to eq(:full)
  end

  def build_run(trigger:)
    Integrations::Medelement::SyncRun.new(
      account: account,
      hook: hook,
      trigger: trigger,
      requested_phases: ['receptions']
    )
  end

  def create_full_audit(completed_at:, phase_status: 'succeeded', status: 'succeeded')
    Integrations::Medelement::SyncRun.create!(
      account: account,
      hook: hook,
      trigger: 'scheduled',
      status: status,
      requested_phases: ['receptions'],
      phase_results: { receptions: { status: phase_status, window_mode: 'full' } },
      completed_at: completed_at,
      created_at: completed_at
    )
  end
end
