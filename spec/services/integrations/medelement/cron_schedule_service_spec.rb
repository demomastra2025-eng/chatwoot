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

  it 'creates realtime, operational and catalog schedules with exact phases' do
    hook = build_stubbed(:integrations_hook, :medelement, account: account)

    described_class.new(hook: hook).sync!

    expect(Sidekiq::Cron::Job).to have_received(:create).with(
      hash_including(
        name: "integrations_medelement_hook_#{hook.id}_realtime",
        klass: 'Integrations::Medelement::SyncJob',
        cron: '*/2 * * * * Asia/Almaty',
        args: [hook.id, nil, %w[receptions]],
        active_job: true,
        queue: 'medium',
        status: 'enabled'
      )
    )
    expect(Sidekiq::Cron::Job).to have_received(:create).with(
      hash_including(
        name: "integrations_medelement_hook_#{hook.id}_operational",
        klass: 'Integrations::Medelement::SyncJob',
        cron: '0,15,30,45 * * * * Asia/Almaty',
        args: [hook.id, nil, %w[specialists contacts receptions]],
        active_job: true,
        queue: 'medium',
        status: 'enabled'
      )
    )
    expect(Sidekiq::Cron::Job).to have_received(:create).with(
      hash_including(
        name: "integrations_medelement_hook_#{hook.id}_catalog",
        cron: '20 0,6,12,18 * * * Asia/Almaty',
        args: [hook.id, nil, %w[setup services]]
      )
    )
    expect(Sidekiq::Cron::Job).to have_received(:destroy).with("integrations_medelement_hook_#{hook.id}")
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
    allow(Sidekiq::Cron::Job).to receive(:create).and_return(false, true, true)

    expect(described_class.new(hook: hook).sync!).to be(false)
    expect(Sidekiq::Cron::Job).to have_received(:create).exactly(3).times
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
end
