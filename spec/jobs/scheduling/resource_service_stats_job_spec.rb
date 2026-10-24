require 'rails_helper'

RSpec.describe Scheduling::ResourceServiceStatsJob do
  let(:account) { create(:account) }

  it 'rebuilds the pairs of one account' do
    aggregator = instance_double(Scheduling::ResourceServiceStatsAggregator, perform: Scheduling::ResourceServiceStatsAggregator::Result.new(
      account_id: account.id, history_pairs: 0, counted_pairs: 0, created: 0, updated: 0, staled: 0, unchanged: 0, dry_run: false
    ))
    allow(Scheduling::ResourceServiceStatsAggregator).to receive(:new).with(account: account).and_return(aggregator)

    described_class.perform_now(account.id)

    expect(aggregator).to have_received(:perform)
  end

  it 'queues one run per account with an enabled MedElement integration and nothing for the others' do
    other_account = create(:account)
    create(:account)
    [account, other_account].each { |item| item.enable_features!('scheduling') }
    create(:integrations_hook, :medelement, account: account)
    create(:integrations_hook, :medelement, account: other_account, status: 'disabled')

    expect { described_class.perform_now }.to have_enqueued_job(described_class).with(account.id).exactly(:once)
    expect(described_class.account_ids).to eq([account.id])
  end

  it 'is scheduled nightly on the scheduled jobs queue' do
    schedule = YAML.safe_load(Rails.root.join('config/schedule.yml').read)

    expect(schedule['medelement_resource_service_stats_job']).to include(
      'cron' => '30 4 * * * Asia/Almaty', 'class' => described_class.name, 'queue' => 'scheduled_jobs', 'active_job' => true
    )
  end
end
