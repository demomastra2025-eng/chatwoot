require 'rails_helper'

RSpec.describe Integrations::Medelement::SyncRun, type: :model do
  let(:account) { create(:account) }
  let(:hook) { create(:integrations_hook, account: account) }

  it 'records a successful phase lifecycle and summary' do
    run = described_class.create!(account: account, hook: hook, trigger: 'manual')

    run.start!
    run.start_phase!('services')
    run.complete_phase!('services', imported_count: 3, skipped_count: 0)
    run.finish!

    expect(run).to have_attributes(status: 'succeeded', current_phase: nil)
    expect(run.phase_results.dig('services', 'imported_count')).to eq(3)
    expect(run.summary).to include('open_conflicts' => 0, 'skipped_count' => 0)
  end

  it 'finishes as partial when a completed phase reports skipped rows' do
    run = described_class.create!(account: account, hook: hook, trigger: 'manual')

    run.start!
    run.complete_phase!('services', imported_count: 2, skipped_count: 1)
    run.finish!

    expect(run).to be_partial
    expect(run.summary['skipped_count']).to eq(1)
  end

  it 'rejects unsupported retry phases' do
    run = described_class.new(
      account: account,
      hook: hook,
      trigger: 'retry',
      requested_phases: ['unknown']
    )

    expect(run).not_to be_valid
    expect(run.errors[:requested_phases]).to include('contains unsupported phases')
  end

  it 'does not persist arbitrary exception text in a failed run' do
    run = described_class.create!(account: account, hook: hook, trigger: 'manual')

    run.fail!(StandardError.new('Patient Jane Doe with identifier 123456789012 failed'))

    expect(run.error_message).to eq('MedElement synchronization failed')
    expect(run.error_message).not_to include('Jane Doe', '123456789012')
  end

  it 'blocks Medelement hook deletion while a sync run is active' do
    account.enable_features!('scheduling')
    schedule_service = instance_double(Integrations::Medelement::CronScheduleService, sync!: true)
    allow(Integrations::Medelement::CronScheduleService).to receive(:new).and_return(schedule_service)
    medelement_hook = create(:integrations_hook, :medelement, account: account)
    run = described_class.create!(account: account, hook: medelement_hook, trigger: 'manual')

    expect(medelement_hook.destroy).to be(false)
    expect(medelement_hook.errors[:base]).to include('Cannot remove Medelement integration while synchronization is active')
    expect(run.reload.hook).to eq(medelement_hook)
  end
end
