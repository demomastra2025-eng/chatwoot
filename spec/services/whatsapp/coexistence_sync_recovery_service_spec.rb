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
          'onboarded_at' => 1.hour.ago.iso8601,
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
            'onboarded_at' => 1.hour.ago.iso8601,
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

  it 'routes persisted history failures to local replay without rotating the provider generation' do
    result = nil

    expect do
      result = described_class.new(channel: channel).perform
    end.to have_enqueued_job(Whatsapp::CoexistenceHistoryFailureRecoveryJob).with(
      channel.id,
      hash_including(
        account_id: channel.account_id,
        business_account_id: 'waba-1',
        phone_number_id: 'phone-1',
        sync_generation: 'failed-generation',
        failure_recovery_id: kind_of(String)
      )
    )

    sync = channel.reload.provider_config['coexistence_sync']
    expect(result).to include(status: 'local_replay_enqueued', generation: 'failed-generation')
    expect(sync).to include(
      'state' => 'history_failed',
      'generation' => 'failed-generation',
      'failure_recovery_id' => kind_of(String),
      'failure_recovery_started_at' => kind_of(String)
    )
    expect(sync['history_failed_messages']).to contain_exactly(include('id' => 'wamid.edit-1'))
    expect(sync).to include('history_request_state' => 'requested', 'history_request_id' => 'stale-request')
  end

  it 'exposes an operator-only recovery entrypoint' do
    expect do
      result = described_class.perform(channel.id)
      expect(result).to include(status: 'local_replay_enqueued')
    end.to have_enqueued_job(Whatsapp::CoexistenceHistoryFailureRecoveryJob)
  end

  it 'does not enqueue a duplicate while local recovery is already active' do
    first = described_class.new(channel: channel).perform
    clear_enqueued_jobs

    expect do
      result = described_class.new(channel: channel).perform
      expect(result).to include(status: 'already_in_progress', generation: first[:generation])
    end.not_to have_enqueued_job(Whatsapp::CoexistenceHistoryFailureRecoveryJob)
  end

  it 'opens a fresh provider generation when no replayable local ledger exists' do
    config = channel.provider_config.deep_dup
    config['coexistence_sync'].delete('history_failed_messages')
    channel.update!(provider_config: config)

    expect do
      result = described_class.new(channel: channel).perform
      expect(result).to include(status: 'enqueued')
    end.to have_enqueued_job(Whatsapp::CoexistenceSyncJob).with(channel.id, kind_of(String))
  end

  it 'refuses a provider resynchronization outside the Meta onboarding window' do
    config = channel.provider_config.deep_dup
    config['coexistence_sync'].delete('history_failed_messages')
    config['coexistence_sync']['onboarded_at'] = 25.hours.ago.iso8601
    channel.update!(provider_config: config)

    expect do
      described_class.new(channel: channel).perform
    end.to raise_error(ArgumentError, 'Meta coexistence synchronization window has expired; local recovery data is required')

    expect(enqueued_jobs).not_to include(hash_including(job: Whatsapp::CoexistenceSyncJob))
    expect(channel.reload.provider_config.dig('coexistence_sync', 'generation')).to eq('failed-generation')
  end

  it 'refuses a provider resynchronization when the onboarding window cannot be proven' do
    config = channel.provider_config.deep_dup
    config['coexistence_sync'].delete('history_failed_messages')
    config['coexistence_sync'].delete('onboarded_at')
    channel.update!(provider_config: config)

    expect do
      described_class.new(channel: channel).perform
    end.to raise_error(ArgumentError, 'Valid coexistence onboarding timestamp is required for provider recovery')
    expect(enqueued_jobs).not_to include(hash_including(job: Whatsapp::CoexistenceSyncJob))
  end

  it 'reclaims a stale recovery claim and enqueues a fresh generation' do
    stale_generation = SecureRandom.uuid
    config = channel.provider_config.deep_dup
    config['coexistence_sync'] = {
      'state' => 'pending',
      'generation' => stale_generation,
      'onboarded_at' => 1.hour.ago.iso8601,
      'recovery_started_at' => 31.minutes.ago.iso8601
    }
    channel.update!(provider_config: config)

    result = described_class.new(channel: channel).perform

    expect(result).to include(status: 'enqueued')
    expect(result[:generation]).not_to eq(stale_generation)
  end

  it 'restores the failed generation when enqueueing the recovery fails' do
    config = channel.provider_config.deep_dup
    config['coexistence_sync'].delete('history_failed_messages')
    channel.update!(provider_config: config)
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

  it 'clears only the local recovery lease when local enqueueing fails' do
    enqueue_error = StandardError.new('redis unavailable')
    failed_job = instance_double(
      Whatsapp::CoexistenceHistoryFailureRecoveryJob,
      successfully_enqueued?: false,
      enqueue_error: enqueue_error
    )
    allow(Whatsapp::CoexistenceHistoryFailureRecoveryJob).to receive(:perform_later).and_return(failed_job)

    expect do
      described_class.new(channel: channel).perform
    end.to raise_error(described_class::EnqueueError, 'redis unavailable')

    sync = channel.reload.provider_config['coexistence_sync']
    expect(sync).not_to include('failure_recovery_id', 'failure_recovery_started_at')
    expect(sync['history_failed_messages']).to contain_exactly(include('id' => 'wamid.edit-1'))
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
