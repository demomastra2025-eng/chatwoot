require 'rails_helper'

RSpec.describe Whatsapp::CoexistenceDeadHistoryRecoveryJob do
  let(:channel) do
    create(
      :channel_whatsapp,
      phone_number: '+15550002030',
      provider: 'whatsapp_cloud',
      sync_templates: false,
      validate_provider_config: false,
      provider_config: {
        'api_key' => 'token',
        'phone_number_id' => 'phone-1',
        'business_account_id' => 'waba-1',
        'embedded_signup_flow' => 'coexistence',
        'coexistence_sync' => { 'generation' => 'generation-1', 'state' => 'history_failed' }
      }
    ).tap do |record|
      record.update!(
        provider_config: record.provider_config.merge(
          'api_key' => 'token',
          'phone_number_id' => 'phone-1',
          'business_account_id' => 'waba-1',
          'embedded_signup_flow' => 'coexistence',
          'coexistence_sync' => { 'generation' => 'generation-1', 'state' => 'history_failed' }
        )
      )
    end
  end
  let(:history_value) { { 'history' => [{ 'threads' => [] }] } }
  let(:source_context) do
    {
      'business_account_id' => 'waba-1',
      'sync_generation' => 'old-generation',
      'provider_event_at' => 1_600_000_000,
      'metadata' => { 'phone_number_id' => 'phone-1', 'display_phone_number' => '15550002030' }
    }
  end
  let(:dead_job) do
    instance_double(
      Sidekiq::SortedEntry,
      display_class: 'Whatsapp::CoexistenceWebhookSyncJob',
      item: { 'error_class' => 'Whatsapp::WabaLock::LockAcquisitionError' },
      args: [{ 'arguments' => [12, 'history', history_value, source_context] }],
      delete: true
    )
  end
  let(:lock_manager) { instance_double(Redis::LockManager, lock: true, unlock: true) }

  before do
    allow(Redis::LockManager).to receive(:new).and_return(lock_manager)
    allow(Sidekiq::DeadSet).to receive(:new).and_return([dead_job])
  end

  it 'reports a matching dead payload before a generation rotation' do
    expect(described_class.pending_payload?(channel)).to be(true)
  end

  it 'exposes an operator-only start entrypoint' do
    expect do
      described_class.start(channel.id)
    end.to have_enqueued_job(described_class).with(channel.id)
  end

  it 'serially replays a matching payload and durably schedules continuation before deleting the source' do
    sync_job = instance_double(Whatsapp::CoexistenceWebhookSyncJob)
    scheduler = class_double(described_class)
    continuation = instance_double(described_class, successfully_enqueued?: true)
    expect(lock_manager).to receive(:lock).with(
      "whatsapp:coexistence:dead-history-recovery:#{channel.id}:waba-1",
      30.minutes
    ).and_return(true)
    expect(lock_manager).to receive(:unlock).with("whatsapp:coexistence:dead-history-recovery:#{channel.id}:waba-1")
    allow(Whatsapp::CoexistenceWebhookSyncJob).to receive(:new).and_return(sync_job)
    expect(sync_job).to receive(:perform).with(
      channel.id,
      'history',
      history_value,
      {
        account_id: channel.account_id,
        provider: 'whatsapp_cloud',
        business_account_id: 'waba-1',
        sync_generation: 'generation-1',
        metadata: { phone_number_id: 'phone-1', display_phone_number: '15550002030' }
      }
    ).ordered.and_return(true)
    expect(described_class).to receive(:set).with(wait: 5.seconds).ordered.and_return(scheduler)
    expect(scheduler).to receive(:perform_later).with(channel.id).ordered.and_return(continuation)
    expect(dead_job).to receive(:delete).ordered

    expect(described_class.perform_now(channel.id)).to eq(:replayed)
  end

  it 'leaves a dead payload untouched when its provider identity does not match' do
    source_context['metadata']['phone_number_id'] = 'other-phone'
    allow(dead_job).to receive(:delete)

    expect(described_class.perform_now(channel.id)).to eq(:complete)
    expect(dead_job).not_to have_received(:delete)
  end

  it 'rejects an explicit cross-account recovery identity' do
    source_context['account_id'] = channel.account_id + 1
    allow(dead_job).to receive(:delete)

    expect(described_class.perform_now(channel.id)).to eq(:complete)
    expect(dead_job).not_to have_received(:delete)
  end

  it 'does not delete a source payload when dispatch rejects it' do
    sync_job = instance_double(Whatsapp::CoexistenceWebhookSyncJob, perform: false)
    allow(Whatsapp::CoexistenceWebhookSyncJob).to receive(:new).and_return(sync_job)
    allow(dead_job).to receive(:delete)

    expect do
      described_class.perform_now(channel.id)
    end.to raise_error(described_class::InvalidRecoveryPayloadError)
    expect(dead_job).not_to have_received(:delete)
  end

  it 'does not delete a source payload when continuation enqueueing fails' do
    sync_job = instance_double(Whatsapp::CoexistenceWebhookSyncJob, perform: true)
    scheduler = class_double(described_class)
    continuation = instance_double(described_class, successfully_enqueued?: false)
    allow(Whatsapp::CoexistenceWebhookSyncJob).to receive(:new).and_return(sync_job)
    allow(described_class).to receive(:set).with(wait: 5.seconds).and_return(scheduler)
    allow(scheduler).to receive(:perform_later).with(channel.id).and_return(continuation)
    allow(dead_job).to receive(:delete)

    expect do
      described_class.perform_now(channel.id)
    end.to raise_error(described_class::EnqueueError)
    expect(dead_job).not_to have_received(:delete)
  end

  it 'rejects a target that is no longer a coexistence channel' do
    channel.update!(provider_config: channel.provider_config.merge('embedded_signup_flow' => 'new'))

    expect do
      described_class.perform_now(channel.id)
    end.to raise_error(described_class::InvalidRecoveryPayloadError)
  end
end
