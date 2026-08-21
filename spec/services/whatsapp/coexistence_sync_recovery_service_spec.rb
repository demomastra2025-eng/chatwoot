require 'rails_helper'

RSpec.describe Whatsapp::CoexistenceSyncRecoveryService do
  let(:channel) do
    create(
      :channel_whatsapp,
      provider: 'whatsapp_cloud',
      sync_templates: false,
      validate_provider_config: false,
      provider_config: {
        'api_key' => 'token',
        'phone_number_id' => 'phone-1',
        'business_account_id' => 'waba-1',
        'embedded_signup_flow' => 'coexistence',
        'coexistence_sync' => {
          'generation' => 'failed-generation',
          'state' => 'history_failed',
          'history_request_state' => 'requested',
          'history_request_id' => 'stale-request',
          'contacts_quarantined_events_count' => 42,
          'history_failed_messages' => [{
            'id' => 'wamid.edit-1',
            'kind' => 'history_thread',
            'message' => { 'id' => 'wamid.edit-1', 'type' => 'edit' }
          }]
        }
      }
    ).tap do |record|
      record.update!(
        provider_config: record.provider_config.merge(
          'api_key' => 'token',
          'phone_number_id' => 'phone-1',
          'business_account_id' => 'waba-1',
          'embedded_signup_flow' => 'coexistence',
          'coexistence_sync' => {
            'generation' => 'failed-generation',
            'state' => 'history_failed',
            'history_request_state' => 'requested',
            'history_request_id' => 'stale-request',
            'contacts_quarantined_events_count' => 42,
            'history_failed_messages' => [{
              'id' => 'wamid.edit-1',
              'kind' => 'history_thread',
              'message' => { 'id' => 'wamid.edit-1', 'type' => 'edit' }
            }]
          }
        )
      )
    end
  end
  let(:lock) { instance_double(Whatsapp::WabaLock) }

  before do
    allow(Whatsapp::WabaLock).to receive(:new).with('waba-1').and_return(lock)
    allow(lock).to receive(:with_lock).and_yield
    allow(Whatsapp::CoexistenceDeadHistoryRecoveryJob).to receive(:pending_payload?).with(channel).and_return(false)
  end

  it 'opens one fresh generation while preserving deferred history failures' do
    result = nil

    expect do
      result = described_class.new(channel: channel).perform
    end.to have_enqueued_job(Whatsapp::CoexistenceSyncJob).with(channel.id, kind_of(String))

    sync = channel.reload.provider_config['coexistence_sync']
    expect(result).to include(status: 'enqueued', generation: sync['generation'])
    expect(sync).to include(
      'state' => 'pending',
      'recovery_source_generation' => 'failed-generation',
      'recovery_source_state' => 'history_failed',
      'recovery_history_failed_messages_count' => 1,
      'recovery_contacts_quarantined_events_count' => 42
    )
    expect(sync['history_failed_messages']).to contain_exactly(include('id' => 'wamid.edit-1'))
    expect(sync).not_to include('history_request_state', 'history_request_id')
  end

  it 'exposes an operator-only recovery entrypoint' do
    expect do
      result = described_class.perform(channel.id)
      expect(result).to include(status: 'enqueued')
    end.to have_enqueued_job(Whatsapp::CoexistenceSyncJob).with(channel.id, kind_of(String))
  end

  it 'does not enqueue a duplicate while recovery is already active' do
    first = described_class.new(channel: channel).perform
    clear_enqueued_jobs

    expect do
      result = described_class.new(channel: channel).perform
      expect(result).to include(status: 'already_in_progress', generation: first[:generation])
    end.not_to have_enqueued_job(Whatsapp::CoexistenceSyncJob)
  end

  it 'reclaims a stale recovery claim and enqueues a fresh generation' do
    stale_generation = SecureRandom.uuid
    config = channel.provider_config.deep_dup
    config['coexistence_sync'] = {
      'state' => 'pending',
      'generation' => stale_generation,
      'recovery_started_at' => 31.minutes.ago.iso8601
    }
    channel.update!(provider_config: config)

    result = described_class.new(channel: channel).perform

    expect(result).to include(status: 'enqueued')
    expect(result[:generation]).not_to eq(stale_generation)
  end

  it 'restores the failed generation when enqueueing the recovery fails' do
    enqueue_error = StandardError.new('redis unavailable')
    failed_job = instance_double(
      Whatsapp::CoexistenceSyncJob,
      successfully_enqueued?: false,
      enqueue_error: enqueue_error
    )
    allow(Whatsapp::CoexistenceSyncJob).to receive(:perform_later).and_return(failed_job)

    expect do
      described_class.new(channel: channel).perform
    end.to raise_error(described_class::EnqueueError, 'redis unavailable')

    expect(channel.reload.provider_config.dig('coexistence_sync', 'generation')).to eq('failed-generation')
    expect(channel.provider_config.dig('coexistence_sync', 'state')).to eq('history_failed')
  end

  it 'refuses to rotate the generation while matching dead history payloads remain' do
    allow(Whatsapp::CoexistenceDeadHistoryRecoveryJob).to receive(:pending_payload?).with(channel).and_return(true)

    expect do
      described_class.new(channel: channel).perform
    end.to raise_error(ArgumentError, 'Dead history payloads must be recovered before opening a fresh synchronization generation')
    expect(channel.reload.provider_config.dig('coexistence_sync', 'generation')).to eq('failed-generation')
  end

  it 'refuses to restart a completed synchronization' do
    config = channel.provider_config.deep_dup
    config['coexistence_sync']['state'] = 'completed'
    channel.update!(provider_config: config)

    expect do
      described_class.new(channel: channel).perform
    end.to raise_error(ArgumentError, 'Coexistence sync state completed is not recoverable')
  end
end
