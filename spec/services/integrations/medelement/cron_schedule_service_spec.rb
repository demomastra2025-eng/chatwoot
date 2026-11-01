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

  it 'creates staggered realtime, operational, contacts, catalog and daytime/night delta schedules' do
    hook = build_stubbed(:integrations_hook, :medelement, account: account)
    config = Integrations::Medelement::Configuration.new(hook: hook)

    described_class.new(hook: hook).sync!

    expect(Sidekiq::Cron::Job).to have_received(:create).with(
      hash_including(
        name: "integrations_medelement_hook_#{hook.id}_realtime",
        klass: 'Integrations::Medelement::ScheduledSyncJob',
        cron: config.receptions_sync_cron_expression,
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
        cron: config.sync_cron_expression,
        args: [hook.id, %w[specialists schedules]],
        active_job: true,
        queue: 'scheduled_jobs',
        status: 'enabled'
      )
    )
    expect(Sidekiq::Cron::Job).to have_received(:create).with(
      hash_including(
        name: "integrations_medelement_hook_#{hook.id}_contacts",
        cron: config.contacts_sync_cron_expression,
        args: [hook.id, %w[contacts]]
      )
    )
    expect(Sidekiq::Cron::Job).to have_received(:create).with(
      hash_including(
        name: "integrations_medelement_hook_#{hook.id}_catalog",
        cron: config.catalog_sync_cron_expression,
        args: [hook.id, %w[setup services]]
      )
    )
    expect(Sidekiq::Cron::Job).to have_received(:destroy).with("integrations_medelement_hook_#{hook.id}")
  end

  it 'adds daytime and staggered nighttime delta jobs without changing the full sweep cron' do
    hook = create(:integrations_hook, :medelement, account: account)
    hook.update!(settings: hook.settings.merge('incremental_receptions_enabled' => true,
                                               'incremental_receptions_interval_seconds' => 30))
    config = Integrations::Medelement::Configuration.new(hook: hook)

    expect(Sidekiq::Cron::Job).to receive(:create).with(
      hash_including(name: "integrations_medelement_hook_#{hook.id}_realtime",
                     cron: config.receptions_sync_cron_expression)
    ).and_return(true)
    expect(Sidekiq::Cron::Job).to receive(:create).with(
      hash_including(name: "integrations_medelement_hook_#{hook.id}_receptions_delta",
                     klass: 'Integrations::Medelement::ReceptionsDeltaJob',
                     cron: '* 7-20 * * * Asia/Almaty',
                     args: [hook.id], queue: 'medelement_sync')
    ).and_return(true)
    expect(Sidekiq::Cron::Job).to receive(:create).with(
      hash_including(name: "integrations_medelement_hook_#{hook.id}_receptions_delta_night",
                     klass: 'Integrations::Medelement::ReceptionsDeltaJob',
                     cron: config.receptions_delta_night_cron_expression,
                     args: [hook.id], queue: 'medelement_sync')
    ).and_return(true)

    described_class.new(hook: hook).sync!
  end

  it 'spreads 100 clinics evenly across minutes so minute :00 never gets a stampede' do
    hooks = (1..100).map do |id|
      instance_double(
        Integrations::Hook,
        id: id,
        account_id: id,
        enabled?: true,
        secret_settings: {},
        settings: {
          'timezone' => 'Asia/Almaty',
          'sync_interval_hours' => 0.25,
          'sync_time_of_day' => '06:15',
          'receptions_full_sweep_interval_minutes' => 60,
          'incremental_receptions_enabled' => true
        }
      )
    end

    operational_at_zero = 0
    realtime_at_zero = 0
    night_delta_at_zero = 0

    hooks.each do |hook|
      cfg = Integrations::Medelement::Configuration.new(hook: hook)
      [
        cfg.receptions_sync_cron_expression,
        cfg.sync_cron_expression,
        cfg.contacts_sync_cron_expression,
        cfg.catalog_sync_cron_expression,
        cfg.receptions_delta_cron_expression,
        cfg.receptions_delta_night_cron_expression
      ].each do |expr|
        expect(Fugit.do_parse_cronish(expr)).to be_present, "Unparseable cron: #{expr}"
      end

      op_mins = cfg.sync_cron_expression.split.first.split(',').map(&:to_i)
      rt_min = cfg.receptions_sync_cron_expression.split.first.to_i
      nd_mins = cfg.receptions_delta_night_cron_expression.split.first.split(',').map(&:to_i)

      operational_at_zero += 1 if op_mins.include?(0)
      realtime_at_zero += 1 if rt_min.zero?
      night_delta_at_zero += 1 if nd_mins.include?(0)
    end

    # Across 100 clinics: ~6-7 per 15-min slot (instead of 100/100) and ~1-2 per 60-min slot (instead of 100/100)
    expect(operational_at_zero).to be <= 8
    expect(realtime_at_zero).to be <= 3
    expect(night_delta_at_zero).to be <= 8
  end

  it 'creates a repeated cron anchored at an explicit custom time for shorter intervals' do
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

  it 'creates a 15 minute cron anchored at an explicit non-default minute' do
    hook = build_stubbed(
      :integrations_hook,
      :medelement,
      account: account,
      settings: build(:integrations_hook, :medelement, account: account).settings.merge(
        'sync_interval_hours' => 0.25,
        'sync_time_of_day' => '06:17'
      )
    )

    described_class.new(hook: hook).sync!

    expect(Sidekiq::Cron::Job).to have_received(:create).with(
      hash_including(cron: '2,17,32,47 * * * * Asia/Almaty')
    )
  end

  it 'creates a 30 minute cron anchored at an explicit non-default minute' do
    hook = build_stubbed(
      :integrations_hook,
      :medelement,
      account: account,
      settings: build(:integrations_hook, :medelement, account: account).settings.merge(
        'sync_interval_hours' => 0.5,
        'sync_time_of_day' => '06:20'
      )
    )

    described_class.new(hook: hook).sync!

    expect(Sidekiq::Cron::Job).to have_received(:create).with(
      hash_including(cron: '20,50 * * * * Asia/Almaty')
    )
  end

  it 'attempts every schedule when one cron job cannot be created' do
    hook = build_stubbed(:integrations_hook, :medelement, account: account)
    allow(Sidekiq::Cron::Job).to receive(:create).and_return(false, true, true, true, true, true)

    expect(described_class.new(hook: hook).sync!).to be(false)
    expect(Sidekiq::Cron::Job).to have_received(:create).exactly(6).times
  end

  it 'carries the catalog offset into the next hour for an explicit custom time' do
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
        'sync_time_of_day' => '06:17'
      )
    )

    described_class.new(hook: hook).sync!

    expect(Sidekiq::Cron::Job).to have_received(:create).with(
      hash_including(
        name: "integrations_medelement_hook_#{hook.id}_operational",
        cron: '2,17,32,47 * * * * Asia/Almaty'
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

    it 'still creates the daytime/night delta jobs and the staggered full sweep job' do
      config = Integrations::Medelement::Configuration.new(hook: hook)
      expect(Sidekiq::Cron::Job).to receive(:create).with(
        hash_including(name: "integrations_medelement_hook_#{hook.id}_receptions_delta",
                       klass: 'Integrations::Medelement::ReceptionsDeltaJob', args: [hook.id])
      ).and_return(true)
      expect(Sidekiq::Cron::Job).to receive(:create).with(
        hash_including(name: "integrations_medelement_hook_#{hook.id}_receptions_delta_night",
                       klass: 'Integrations::Medelement::ReceptionsDeltaJob', args: [hook.id])
      ).and_return(true)
      expect(Sidekiq::Cron::Job).to receive(:create).with(
        hash_including(name: "integrations_medelement_hook_#{hook.id}_realtime",
                       cron: config.receptions_sync_cron_expression)
      ).and_return(true)

      expect(described_class.new(hook: hook).sync!).to be(true)
    end

    it 'removes both daytime and nighttime delta jobs when fast sync is off' do
      hook.update!(settings: hook.settings.merge('incremental_receptions_enabled' => false))

      described_class.new(hook: hook).sync!

      expect(Sidekiq::Cron::Job).to have_received(:destroy)
        .with("integrations_medelement_hook_#{hook.id}_receptions_delta").at_least(:once)
      expect(Sidekiq::Cron::Job).to have_received(:destroy)
        .with("integrations_medelement_hook_#{hook.id}_receptions_delta_night").at_least(:once)
    end

    it 'lets the full-sweep backoff step change the staggered schedule' do
      Integrations::Medelement::SyncCursor.create!(
        hook: hook, name: backoff_name, current_interval_seconds: 120, last_success_at: Time.current
      )
      Integrations::Medelement::SyncCursor.create!(
        hook: hook, name: 'receptions_delta', value: 1.minute.ago, last_poll_at: 30.seconds.ago, last_success_at: 30.seconds.ago
      )
      offset = ((hook.id * 7) + 3) % 4
      expected_min = offset.zero? ? '*/4' : "#{offset}-59/4"
      expect(Sidekiq::Cron::Job).to receive(:create).with(
        hash_including(name: "integrations_medelement_hook_#{hook.id}_realtime",
                       cron: "#{expected_min} * * * * Asia/Almaty")
      ).and_return(true)

      Integrations::Medelement::DeltaMissAudit.new(hook: hook).record_full_sweep_result!
    end

    it 'lets the backoff reset change the staggered schedule back' do
      Integrations::Medelement::SyncCursor.create!(hook: hook, name: backoff_name, current_interval_seconds: 900)
      offset = ((hook.id * 7) + 3) % 2
      expected_min = offset.zero? ? '*/2' : "#{offset}-59/2"
      expect(Sidekiq::Cron::Job).to receive(:create).with(
        hash_including(name: "integrations_medelement_hook_#{hook.id}_realtime",
                       cron: "#{expected_min} * * * * Asia/Almaty")
      ).and_return(true)

      Integrations::Medelement::DeltaMissAudit.new(hook: hook).reset_full_sweep_backoff!(reason: 'delta_miss')
    end

    it 'writes the daytime and night delta jobs to Redis, where the poller of another process finds them' do
      allow(Sidekiq::Cron::Job).to receive(:create).and_call_original
      allow(Sidekiq::Cron::Job).to receive(:destroy).and_call_original
      allow(Sidekiq::Cron::Job).to receive(:find).and_call_original

      described_class.new(hook: hook).sync!

      day_job = Sidekiq::Cron::Job.find("integrations_medelement_hook_#{hook.id}_receptions_delta")
      night_job = Sidekiq::Cron::Job.find("integrations_medelement_hook_#{hook.id}_receptions_delta_night")
      expect(day_job).to have_attributes(
        klass: 'Integrations::Medelement::ReceptionsDeltaJob',
        cron: '* 7-20 * * * Asia/Almaty'
      )
      expect(night_job).to have_attributes(
        klass: 'Integrations::Medelement::ReceptionsDeltaJob',
        cron: Integrations::Medelement::Configuration.new(hook: hook).receptions_delta_night_cron_expression
      )
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
