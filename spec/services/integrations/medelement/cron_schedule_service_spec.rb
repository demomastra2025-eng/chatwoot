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

  it 'creates a daily cron from the selected Medelement time and timezone' do
    hook = create(:integrations_hook, :medelement, account: account)

    described_class.new(hook: hook).sync!

    expect(Sidekiq::Cron::Job).to have_received(:create).with(
      hash_including(
        name: "integrations_medelement_hook_#{hook.id}",
        klass: 'Integrations::Medelement::SyncJob',
        cron: '15 6 * * * Asia/Almaty',
        args: [hook.id],
        active_job: true,
        queue: 'medium',
        status: 'enabled'
      )
    )
  end

  it 'creates a repeated cron anchored at the chosen time for shorter intervals' do
    hook = create(
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
