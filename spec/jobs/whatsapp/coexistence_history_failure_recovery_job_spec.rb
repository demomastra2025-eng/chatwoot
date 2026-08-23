require 'rails_helper'

RSpec.describe Whatsapp::CoexistenceHistoryFailureRecoveryJob do
  let(:recovery_id) { 'recovery-1' }
  let(:channel) do
    create(
      :channel_whatsapp,
      phone_number: '+155****2030',
      provider: 'whatsapp_cloud',
      sync_templates: false,
      validate_provider_config: false,
      provider_config: {
        'api_key' => 'token',
        'phone_number_id' => 'phone-1',
        'business_account_id' => 'waba-1',
        'embedded_signup_flow' => 'coexistence',
        'coexistence_sync' => {
          'generation' => 'generation-1',
          'state' => 'history_failed',
          'failure_recovery_id' => recovery_id,
          'failure_recovery_started_at' => Time.current.iso8601,
          'history_failed_messages' => failures
        }
      }
    )
  end
  let(:failures) do
    Array.new(12) do |index|
      id = format('wamid.failure-%02d', index)
      {
        'id' => id,
        'kind' => 'history_media',
        'message' => { 'id' => id, 'type' => 'image', 'image' => { 'id' => "media-#{index}" } },
        'metadata' => { 'phone_number_id' => 'phone-1' },
        'replayable' => true
      }
    end
  end
  let(:identity) do
    {
      account_id: channel.account_id,
      provider: 'whatsapp_cloud',
      business_account_id: channel.provider_config['business_account_id'],
      phone_number_id: channel.provider_config['phone_number_id'],
      phone_number: channel.phone_number,
      sync_generation: 'generation-1',
      failure_recovery_id: recovery_id
    }
  end
  let(:lock_manager) { instance_double(Redis::LockManager, lock: true, unlock: true) }
  let(:waba_lock) { instance_double(Whatsapp::WabaLock) }
  let(:history_service) { instance_double(Whatsapp::CoexistenceHistoryService) }

  before do
    conversation = create(:conversation, account: channel.account, inbox: channel.inbox)
    failures.each do |failure|
      create(
        :message,
        account: channel.account,
        inbox: channel.inbox,
        conversation: conversation,
        source_id: failure['id'],
        content_attributes: {
          'imported_history' => true,
          'whatsapp_history_original_type' => 'media_placeholder'
        }
      )
    end
    allow(Redis::LockManager).to receive(:new).and_return(lock_manager)
    allow(Whatsapp::WabaLock).to receive(:new).with(channel.provider_config['business_account_id']).and_return(waba_lock)
    allow(waba_lock).to receive(:with_lock).and_yield
    allow(Whatsapp::WabaLivePriority).to receive(:waiting?).with(channel.provider_config['business_account_id']).and_return(false)
    allow(Whatsapp::CoexistenceHistoryService).to receive(:new).and_return(history_service)
    allow(history_service).to receive(:replay_failures)
  end

  it 'uses a recovery-only queue that legacy history workers do not consume' do
    rendered_config = ERB.new(File.read(Rails.root.join('config/sidekiq_whatsappweb_history.yml'))).result
    worker_config = YAML.safe_load(rendered_config, permitted_classes: [Symbol], aliases: true)

    expect(described_class.queue_name).to eq('whatsappweb_history_recovery')
    expect(described_class.queue_name).not_to eq(Whatsapp::CoexistenceWebhookSyncJob.queue_name)
    expect(worker_config[:queues]).to eq(%w[whatsappweb_history whatsappweb_history_recovery])
    expect(described_class.new(channel.id, identity).serialize['queue_name']).to eq('whatsappweb_history_recovery')
  end

  it 'replays one bounded batch and durably schedules the next cursor' do
    expected_ids = failures.first(described_class::BATCH_SIZE).pluck('id')
    allow(history_service).to receive(:replay_failures).with(failure_ids: expected_ids).and_return(
      requested_ids: expected_ids,
      failed_ids: []
    )

    previous_lease = Time.zone.parse(channel.provider_config.dig('coexistence_sync', 'failure_recovery_started_at'))
    travel 1.second do
      expect do
        result = described_class.perform_now(channel.id, identity)
        expect(result).to eq(status: 'replayed', requested_count: 10, failed_count: 0)
      end.to have_enqueued_job(described_class).with(
        channel.id,
        hash_including('failure_recovery_id' => recovery_id),
        expected_ids.last
      ).at(a_value > Time.current)

      refreshed_lease = Time.zone.parse(channel.reload.provider_config.dig('coexistence_sync', 'failure_recovery_started_at'))
      expect(refreshed_lease).to be > previous_lease
    end
  end

  it 'wraps the cursor to retry an unresolved failure that sorts before the completed batch tail' do
    unresolved_failure = {
      'id' => 'wamid.failure-a',
      'kind' => 'history_thread',
      'message' => { 'id' => 'wamid.failure-a', 'type' => 'text', 'text' => { 'body' => 'retry me' } },
      'metadata' => { 'phone_number_id' => 'phone-1' },
      'replayable' => true
    }
    completed_failure = unresolved_failure.deep_dup.tap { |failure| failure['id'] = failure['message']['id'] = 'wamid.failure-z' }
    config = channel.provider_config.deep_dup
    config['coexistence_sync']['history_failed_messages'] = [completed_failure, unresolved_failure]
    channel.update!(provider_config: config)
    selected_ids = %w[wamid.failure-a wamid.failure-z]
    allow(history_service).to receive(:replay_failures).with(failure_ids: selected_ids) do
      current = channel.reload.provider_config.deep_dup
      current['coexistence_sync']['history_failed_messages'] = [unresolved_failure]
      channel.persist_provider_config_state!(current)
      { requested_ids: selected_ids, failed_ids: [unresolved_failure['id']] }
    end

    expect do
      result = described_class.perform_now(channel.id, identity)
      expect(result).to eq(status: 'replayed', requested_count: 2, failed_count: 1)
    end.to have_enqueued_job(described_class).with(
      channel.id,
      hash_including('failure_recovery_id' => recovery_id),
      nil
    ).at(a_value > Time.current)

    expect(channel.reload.provider_config.dig('coexistence_sync', 'history_failed_messages'))
      .to contain_exactly(include('id' => unresolved_failure['id']))
    expect(channel.provider_config.dig('coexistence_sync', 'failure_recovery_id')).to eq(recovery_id)
  end

  it 'clears the lease and marks a fully proven history stream completed after the final batch' do
    config = channel.provider_config.deep_dup
    config['coexistence_sync']['history_failed_messages'] = failures.first(1)
    config['coexistence_sync']['history_progress'] = 100
    config['coexistence_sync']['smb_app_state_sync_request_state'] = 'completed'
    channel.update!(provider_config: config)
    selected_id = failures.first['id']
    allow(history_service).to receive(:replay_failures).with(failure_ids: [selected_id]) do
      current = channel.reload.provider_config.deep_dup
      current['coexistence_sync'].delete('history_failed_messages')
      channel.persist_provider_config_state!(current)
      { requested_ids: [selected_id], failed_ids: [] }
    end

    expect do
      described_class.perform_now(channel.id, identity)
    end.not_to have_enqueued_job(described_class)

    sync = channel.reload.provider_config['coexistence_sync']
    expect(sync).to include(
      'state' => 'completed',
      'history_request_state' => 'completed',
      'failure_recovery_completed_at' => kind_of(String)
    )
    expect(sync).not_to include('failure_recovery_id', 'failure_recovery_started_at')
  end

  it 'leaves media failures durable without queueing retries until their placeholders exist' do
    missing_failure = failures.first
    channel.inbox.messages.find_by!(source_id: missing_failure['id']).destroy!
    config = channel.provider_config.deep_dup
    config['coexistence_sync']['history_failed_messages'] = [missing_failure]
    channel.update!(provider_config: config)

    expect do
      result = described_class.perform_now(channel.id, identity)
      expect(result).to eq(status: 'complete', requested_count: 0, failed_count: 0)
    end.not_to have_enqueued_job(described_class)

    expect(history_service).not_to have_received(:replay_failures)
    sync = channel.reload.provider_config['coexistence_sync']
    expect(sync).to include(
      'state' => 'history_failed',
      'failure_recovery_completed_at' => kind_of(String)
    )
    expect(sync['history_failed_messages']).to contain_exactly(include('id' => missing_failure['id']))
    expect(sync).not_to include('failure_recovery_id', 'failure_recovery_started_at')
  end

  it 'fails closed when the provider identity changes' do
    original_identity = identity.deep_dup
    channel.update!(provider_config: channel.provider_config.merge('phone_number_id' => 'other-phone'))

    expect do
      described_class.perform_now(channel.id, original_identity)
    end.to raise_error(described_class::InvalidRecoveryStateError, 'Coexistence recovery identity changed')
    expect(history_service).not_to have_received(:replay_failures)
  end
end
