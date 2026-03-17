require 'rails_helper'

RSpec.describe Channels::WhatsappWeb::HistorySyncJob do
  let(:lock_manager) { instance_double(Redis::LockManager) }

  around do |example|
    with_modified_env(
      'EVOLUTION_API_URL' => 'https://evolution.example.com',
      'EVOLUTION_API_KEY' => 'test-api-key',
      'FRONTEND_URL' => 'https://app.example.com'
    ) do
      example.run
    end
  end

  before do
    allow(Redis::LockManager).to receive(:new).and_return(lock_manager)
    allow(lock_manager).to receive(:lock).and_return(true)
    allow(lock_manager).to receive(:unlock).and_return(true)
  end

  it 'runs on the whatsappweb_history queue' do
    expect(described_class.queue_name).to eq('whatsappweb_history')
  end

  it 'delegates to the history sync service' do
    channel = create(:channel_whatsapp_web)
    service = instance_double(WhatsappWeb::HistorySyncService, perform: true)

    expect(lock_manager).to receive(:lock).with(
      format(::Redis::Alfred::WHATSAPP_WEB_HISTORY_SYNC_MUTEX, channel_id: channel.id),
      30.minutes
    ).and_return(true)
    expect(WhatsappWeb::HistorySyncService).to receive(:new).with(channel: channel, mode: 'full', sync_context: {}).and_return(service)
    expect(service).to receive(:perform)

    described_class.perform_now(channel.id, 'full')
  end

  it 'skips stale sync requests superseded by a newer provider snapshot' do
    channel = create(:channel_whatsapp_web)
    channel.update!(
      sync_state: channel.sync_state_payload.merge(
        'history_sync_requested_at' => Time.current.iso8601,
        'provider_history_synced_at' => Time.current.iso8601,
        'history_sync_expected_provider_synced_at' => Time.current.iso8601
      )
    )

    expect(WhatsappWeb::HistorySyncService).not_to receive(:new)

    described_class.perform_now(
      channel.id,
      'full',
      {
        'requested_at' => 1.minute.ago.iso8601,
        'expected_provider_history_synced_at' => 1.minute.ago.iso8601
      }
    )
  end

  it 'skips requests already fulfilled by a newer superseding request' do
    channel = create(:channel_whatsapp_web)
    freeze_time do
      channel.update!(
        sync_state: channel.sync_state_payload.merge(
          'history_sync_requested_at' => Time.current.iso8601
        )
      )

      expect(WhatsappWeb::HistorySyncService).not_to receive(:new)

      described_class.perform_now(
        channel.id,
        'full',
        {
          'requested_at' => 1.minute.ago.iso8601
        }
      )
    end
  end

  it 'does not skip a newer provider snapshot request when only an older snapshot was imported locally' do
    channel = create(:channel_whatsapp_web)
    requested_at = 2.minutes.ago.change(usec: 0)
    expected_snapshot = 1.minute.ago.change(usec: 0)
    service = instance_double(WhatsappWeb::HistorySyncService, perform: true)

    channel.update!(
      sync_state: channel.sync_state_payload.merge(
        'history_sync_requested_at' => requested_at.iso8601,
        'last_fulfilled_history_sync_requested_at' => requested_at.iso8601,
        'last_local_history_sync_finished_at' => Time.current.iso8601,
        'history_sync_expected_provider_synced_at' => expected_snapshot.iso8601,
        'provider_history_synced_at' => expected_snapshot.iso8601,
        'local_history_provider_synced_at' => 5.minutes.ago.iso8601
      )
    )

    expect(WhatsappWeb::HistorySyncService).to receive(:new).with(
      channel: channel,
      mode: 'full',
      sync_context: hash_including(
        'requested_at' => requested_at.iso8601,
        'expected_provider_history_synced_at' => expected_snapshot.iso8601
      )
    ).and_return(service)
    expect(service).to receive(:perform)

    described_class.perform_now(
      channel.id,
      'full',
      {
        'requested_at' => requested_at.iso8601,
        'expected_provider_history_synced_at' => expected_snapshot.iso8601
      }
    )
  end

  it 'rechecks staleness after acquiring the per-channel lock' do
    channel = create(:channel_whatsapp_web)
    requested_at = 1.minute.ago.change(usec: 0)

    expect(lock_manager).to receive(:lock) do |_key, _timeout|
      channel.update!(
        sync_state: channel.sync_state_payload.merge(
          'history_sync_requested_at' => Time.current.iso8601
        )
      )
      true
    end
    expect(WhatsappWeb::HistorySyncService).not_to receive(:new)

    described_class.perform_now(
      channel.id,
      'full',
      {
        'requested_at' => requested_at.iso8601
      }
    )
  end
end
