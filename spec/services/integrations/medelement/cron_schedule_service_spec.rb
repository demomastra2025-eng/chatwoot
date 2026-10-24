require 'rails_helper'

RSpec.describe Integrations::Medelement::CronScheduleService do
  let(:account) { create(:account) }

  before do
    account.enable_features!('scheduling')
    allow(described_class).to receive(:cron_enabled?).and_return(true)
    allow(Sidekiq::Cron::Job).to receive(:create).and_return(true)
    allow(Sidekiq::Cron::Job).to receive(:destroy).and_return(true)
    allow(Sidekiq::Cron::Job).to receive(:all).and_return([])
    allow(Sidekiq::Cron::Job).to receive(:find).and_return(nil)
  end

  it 'creates coalesced realtime, operational, contacts and catalog schedules with exact phases' do
    hook = build_stubbed(:integrations_hook, :medelement, account: account)

    described_class.new(hook: hook).sync!

    expect(Sidekiq::Cron::Job).to have_received(:create).with(
      hash_including(
        name: "integrations_medelement_hook_#{hook.id}_realtime",
        klass: 'Integrations::Medelement::ScheduledSyncJob',
        cron: '*/2 * * * * Asia/Almaty',
        args: [hook.id, %w[receptions]],
        active_job: true,
        queue: 'scheduled_jobs',
        status: 'enabled'
      )
    )
    expect(Sidekiq::Cron::Job).to have_received(:create).with(
      hash_including(
        name: "integrations_medelement_hook_#{hook.id}_operational",
        klass: 'Integrations::Medelement::ScheduledSyncJob',
        cron: '0,15,30,45 * * * * Asia/Almaty',
        args: [hook.id, %w[specialists schedules]],
        active_job: true,
        queue: 'scheduled_jobs',
        status: 'enabled'
      )
    )
    expect(Sidekiq::Cron::Job).to have_received(:create).with(
      hash_including(
        name: "integrations_medelement_hook_#{hook.id}_contacts",
        cron: Integrations::Medelement::Configuration.new(hook: hook).contacts_sync_cron_expression,
        args: [hook.id, %w[contacts]]
      )
    )
    expect(Sidekiq::Cron::Job).to have_received(:create).with(
      hash_including(
        name: "integrations_medelement_hook_#{hook.id}_catalog",
        cron: '20 0,6,12,18 * * * Asia/Almaty',
        args: [hook.id, %w[setup services]]
      )
    )
    expect(Sidekiq::Cron::Job).to have_received(:destroy).with("integrations_medelement_hook_#{hook.id}")
  end

  it 'adds a separate delta job without changing the full sweep cron' do
    hook = create(:integrations_hook, :medelement, account: account)
    hook.update!(settings: hook.settings.merge('incremental_receptions_enabled' => true,
                                               'incremental_receptions_interval_seconds' => 30))

    expect(Sidekiq::Cron::Job).to receive(:create).with(
      hash_including(name: "integrations_medelement_hook_#{hook.id}_realtime", cron: '*/2 * * * * Asia/Almaty')
    ).and_return(true)
    expect(Sidekiq::Cron::Job).to receive(:create).with(
      hash_including(name: "integrations_medelement_hook_#{hook.id}_receptions_delta",
                     klass: 'Integrations::Medelement::ReceptionsDeltaJob', cron: '* * * * * Asia/Almaty',
                     args: [hook.id], queue: 'medelement_sync')
    ).and_return(true)

    described_class.new(hook: hook).sync!
  end

  it 'creates a repeated cron anchored at the chosen time for shorter intervals' do
    hook = build_stubbed(
      :integrations_hook,
      :medelement,
      account: account,
      settings: build(:integrations_hook, :medelement, account: account).settings.merge(
        'sync_interval_hours' => 6,
        'sync_time_of_day' => '13:30'
      )
    )

    described_class.new(hook: hook).sync!

    expect(Sidekiq::Cron::Job).to have_received(:create).with(
      hash_including(cron: '30 1,7,13,19 * * * Asia/Almaty')
    )
  end

  it 'creates a 15 minute cron anchored at the selected minute' do
    hook = build_stubbed(
      :integrations_hook,
      :medelement,
      account: account,
      settings: build(:integrations_hook, :medelement, account: account).settings.merge(
        'sync_interval_hours' => 0.25,
        'sync_time_of_day' => '06:15'
      )
    )

    described_class.new(hook: hook).sync!

    expect(Sidekiq::Cron::Job).to have_received(:create).with(
      hash_including(cron: '0,15,30,45 * * * * Asia/Almaty')
    )
  end

  it 'creates a 30 minute cron anchored at the selected minute' do
    hook = build_stubbed(
      :integrations_hook,
      :medelement,
      account: account,
      settings: build(:integrations_hook, :medelement, account: account).settings.merge(
        'sync_interval_hours' => 0.5,
        'sync_time_of_day' => '06:15'
      )
    )

    described_class.new(hook: hook).sync!

    expect(Sidekiq::Cron::Job).to have_received(:create).with(
      hash_including(cron: '15,45 * * * * Asia/Almaty')
    )
  end

  it 'attempts every schedule when one cron job cannot be created' do
    hook = build_stubbed(:integrations_hook, :medelement, account: account)
    allow(Sidekiq::Cron::Job).to receive(:create).and_return(false, true, true, true, true)

    expect(described_class.new(hook: hook).sync!).to be(false)
    expect(Sidekiq::Cron::Job).to have_received(:create).exactly(5).times
  end

  it 'carries the catalog offset into the next hour' do
    hook = build_stubbed(
      :integrations_hook,
      :medelement,
      account: account,
      settings: build(:integrations_hook, :medelement, account: account).settings.merge('sync_time_of_day' => '06:58')
    )

    described_class.new(hook: hook).sync!

    expect(Sidekiq::Cron::Job).to have_received(:create).with(
      hash_including(
        name: "integrations_medelement_hook_#{hook.id}_catalog",
        cron: '3 1,7,13,19 * * * Asia/Almaty'
      )
    )
  end

  it 'falls back to the safe 15 minute operational interval for unsupported values' do
    hook = build_stubbed(
      :integrations_hook,
      :medelement,
      account: account,
      settings: build(:integrations_hook, :medelement, account: account).settings.merge(
        'sync_interval_hours' => 3,
        'sync_time_of_day' => '06:15'
      )
    )

    described_class.new(hook: hook).sync!

    expect(Sidekiq::Cron::Job).to have_received(:create).with(
      hash_including(
        name: "integrations_medelement_hook_#{hook.id}_operational",
        cron: '0,15,30,45 * * * * Asia/Almaty'
      )
    )
  end

  it 'destroys stale dynamic jobs and the legacy shared dispatch job on full sync' do
    hook = create(:integrations_hook, :medelement, account: account)
    stale_job = instance_double(Sidekiq::Cron::Job, name: 'integrations_medelement_hook_999')
    active_job = instance_double(Sidekiq::Cron::Job, name: "integrations_medelement_hook_#{hook.id}")
    allow(Sidekiq::Cron::Job).to receive(:all).and_return([stale_job, active_job])

    described_class.sync_all!

    expect(Sidekiq::Cron::Job).to have_received(:destroy).with('integrations_medelement_dispatch_job')
    expect(Sidekiq::Cron::Job).to have_received(:destroy).with('integrations_medelement_hook_999')
  end

  # The medelement worker runs with ENABLE_SIDEKIQ_CRON=false (it does not poll cron) but is where the full-sweep
  # backoff changes the schedule, so writing a schedule must not depend on that flag.
  describe 'in a process where ENABLE_SIDEKIQ_CRON is false' do
    let(:hook) do
      create(:integrations_hook, :medelement, account: account).tap do |record|
        record.update!(settings: record.settings.merge('incremental_receptions_enabled' => true))
      end
    end
    let(:backoff_name) { Integrations::Medelement::Configuration::FULL_SWEEP_BACKOFF_CURSOR_NAME }

    around { |example| ClimateControl.modify(ENABLE_SIDEKIQ_CRON: 'false') { example.run } }

    before do
      hook
      allow(described_class).to receive(:cron_enabled?).and_call_original
      allow(Rails.env).to receive(:test?).and_return(false)
    end

    it 'still creates the delta job and the full sweep job' do
      expect(Sidekiq::Cron::Job).to receive(:create).with(
        hash_including(name: "integrations_medelement_hook_#{hook.id}_receptions_delta",
                       klass: 'Integrations::Medelement::ReceptionsDeltaJob', args: [hook.id])
      ).and_return(true)
      expect(Sidekiq::Cron::Job).to receive(:create).with(
        hash_including(name: "integrations_medelement_hook_#{hook.id}_realtime", cron: '*/2 * * * * Asia/Almaty')
      ).and_return(true)

      expect(described_class.new(hook: hook).sync!).to be(true)
    end

    it 'removes the delta job when fast sync is off' do
      hook.update!(settings: hook.settings.merge('incremental_receptions_enabled' => false))

      described_class.new(hook: hook).sync!

      expect(Sidekiq::Cron::Job).to have_received(:destroy).with("integrations_medelement_hook_#{hook.id}_receptions_delta").at_least(:once)
    end

    it 'lets the full-sweep backoff step change the schedule' do
      Integrations::Medelement::SyncCursor.create!(hook: hook, name: backoff_name, current_interval_seconds: 120, last_success_at: Time.current)
      Integrations::Medelement::SyncCursor.create!(hook: hook, name: 'receptions_delta', value: 1.minute.ago, last_poll_at: 30.seconds.ago, last_success_at: 30.seconds.ago)
      expect(Sidekiq::Cron::Job).to receive(:create).with(
        hash_including(name: "integrations_medelement_hook_#{hook.id}_realtime", cron: '*/4 * * * * Asia/Almaty')
      ).and_return(true)

      Integrations::Medelement::DeltaMissAudit.new(hook: hook).record_full_sweep_result!
    end

    it 'lets the backoff reset change the schedule back' do
      Integrations::Medelement::SyncCursor.create!(hook: hook, name: backoff_name, current_interval_seconds: 900)
      expect(Sidekiq::Cron::Job).to receive(:create).with(
        hash_including(name: "integrations_medelement_hook_#{hook.id}_realtime", cron: '*/2 * * * * Asia/Almaty')
      ).and_return(true)

      Integrations::Medelement::DeltaMissAudit.new(hook: hook).reset_full_sweep_backoff!(reason: 'delta_miss')
    end

    it 'writes the jobs to Redis, where the poller of another process finds them' do
      allow(Sidekiq::Cron::Job).to receive(:create).and_call_original
      allow(Sidekiq::Cron::Job).to receive(:destroy).and_call_original
      allow(Sidekiq::Cron::Job).to receive(:find).and_call_original

      described_class.new(hook: hook).sync!

      job = Sidekiq::Cron::Job.find("integrations_medelement_hook_#{hook.id}_receptions_delta")
      expect(job).to have_attributes(klass: 'Integrations::Medelement::ReceptionsDeltaJob', cron: '*/1 * * * * Asia/Almaty')
    ensure
      described_class.new(hook: hook).destroy!
    end

    it 'can still be switched off for a process that must not touch the schedules' do
      ClimateControl.modify(DISABLE_MEDELEMENT_CRON_SYNC: 'true') do
        expect(Sidekiq::Cron::Job).not_to receive(:create)

        expect(described_class.cron_enabled?).to be(false)
        described_class.new(hook: hook).sync!
      end
    end
  end

  it 'never writes schedules in the test environment' do
    allow(described_class).to receive(:cron_enabled?).and_call_original

    expect(described_class.cron_enabled?).to be(false)
  end
end
