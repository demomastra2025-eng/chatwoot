require 'rails_helper'
require 'erb'
require 'yaml'

# rubocop:disable RSpec/DescribeClass
RSpec.describe 'WhatsApp queue priority' do
  def sidekiq_config(name)
    rendered = ERB.new(File.read(Rails.root.join("config/#{name}.yml"))).result
    YAML.safe_load(rendered, permitted_classes: [Symbol], aliases: true)
  end

  it 'isolates official coexistence history from unofficial WhatsApp Web history' do
    official = sidekiq_config('sidekiq_whatsapp_coexistence_history')
    unofficial = sidekiq_config('sidekiq_whatsappweb_history')

    expect(official[:queues]).to eq(
      %w[whatsapp_coexistence_history whatsapp_coexistence_history_recovery whatsappweb_history_recovery]
    )
    expect(unofficial[:queues]).to eq(%w[whatsappweb_history])
    expect(official[:queues] & unofficial[:queues]).to be_empty
  end

  it 'keeps a compatibility consumer for recovery jobs serialized before the queue split' do
    official = sidekiq_config('sidekiq_whatsapp_coexistence_history')

    expect(official[:queues]).to include('whatsappweb_history_recovery')
  end

  it 'keeps unofficial WhatsApp Web workers at one thread by default' do
    expect(sidekiq_config('sidekiq_whatsappweb_inbound')[:concurrency]).to eq(1)
    expect(sidekiq_config('sidekiq_whatsappweb_history')[:concurrency]).to eq(1)
    expect(sidekiq_config('sidekiq_whatsappweb_echo')[:concurrency]).to eq(1)
  end

  it 'preserves official WhatsApp inbound concurrency' do
    expect(sidekiq_config('sidekiq_whatsapp_inbound')[:concurrency]).to eq(4)
  end

  it 'starts separate official and unofficial history consumers in every Procfile' do
    %w[Procfile Procfile.dev Procfile.dev-hybrid Procfile.dev-lite Procfile.tunnel].each do |path|
      procfile = Rails.root.join(path).read

      expect(procfile).to include('sidekiq -C config/sidekiq_whatsapp_coexistence_history.yml')
      expect(procfile).to include('sidekiq -C config/sidekiq_whatsappweb_history.yml')
    end
  end

  it 'routes official coexistence work to the official queues' do
    regular_jobs = [
      Whatsapp::CoexistenceContactPendingEventReconciliationJob,
      Whatsapp::CoexistenceDeadHistoryRecoveryJob,
      Whatsapp::CoexistenceSyncJob,
      Whatsapp::CoexistenceSyncReconciliationJob,
      Whatsapp::CoexistenceWebhookSyncJob
    ]

    expect(regular_jobs.map(&:queue_name).uniq).to eq(['whatsapp_coexistence_history'])
    expect(Whatsapp::CoexistenceHistoryFailureRecoveryJob.queue_name)
      .to eq('whatsapp_coexistence_history_recovery')
  end
end
# rubocop:enable RSpec/DescribeClass
