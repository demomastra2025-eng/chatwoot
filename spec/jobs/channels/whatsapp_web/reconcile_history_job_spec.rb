require 'rails_helper'

RSpec.describe Channels::WhatsappWeb::ReconcileHistoryJob do
  around do |example|
    with_modified_env('EVOLUTION_API_URL' => 'https://evolution.example.com', 'EVOLUTION_API_KEY' => 'test-key') { example.run }
  end

  before do
    Redis::Alfred.delete(described_class::CURSOR_KEY)
  end

  def connected_channel(**attributes)
    create(:channel_whatsapp_web, connection_state: 'open', lifecycle_state: 'connected', **attributes).tap do |channel|
      channel.record_provider_history_snapshot!(message_count: 3, contact_count: 2)
    end
  end

  it 'fills a quiet legacy channel through the existing full pipeline without a provider request in the scan' do
    channel = connected_channel(import_contacts: false, import_messages: false, history_lookback_days: 7)
    expect(WhatsappWeb::Providers::EvolutionService).not_to receive(:new)
    expect { described_class.perform_now }.to have_enqueued_job(Channels::WhatsappWeb::HistorySyncJob).with(
      channel.id, 'full', hash_including('expected_provider_history_synced_at' => channel.provider_history_synced_at.iso8601)
    )
    expect(channel.reload.history_sync_request_pending?).to be(true)
  end

  it 'does not enqueue duplicate work when the operational Redis cursor is lost' do
    connected_channel
    described_class.perform_now
    clear_enqueued_jobs
    Redis::Alfred.delete(described_class::CURSOR_KEY)
    expect { described_class.perform_now }.not_to have_enqueued_job(Channels::WhatsappWeb::HistorySyncJob)
  end

  it 'does not mistake legacy snapshot acknowledgements for completion of the new full policy' do
    channel = connected_channel
    channel.update!(sync_state: channel.sync_state.merge(
      'history_synced_at' => 1.hour.ago.iso8601,
      'local_history_provider_synced_at' => channel.provider_history_synced_at.iso8601,
      'last_history_sync_mode' => 'full'
    ))
    described_class.perform_now
    context = enqueued_jobs.find { |job| job[:job] == Channels::WhatsappWeb::HistorySyncJob }[:args].last
    expect(channel.reload.history_sync_request_pending?).to be(true)
    clear_enqueued_jobs
    expect { described_class.perform_now }.not_to have_enqueued_job(Channels::WhatsappWeb::HistorySyncJob)
    service = instance_double(WhatsappWeb::HistorySyncService, perform: {})
    expect(WhatsappWeb::HistorySyncService).to receive(:new).with(channel: channel, mode: 'full', sync_context: context).and_return(service)
    Channels::WhatsappWeb::HistorySyncJob.perform_now(channel.id, 'full', context)
  end

  it 'does not enqueue a full import while the existing history pipeline holds its runtime mutex' do
    channel = connected_channel
    lock = Redis::LockManager.new
    key = format(Redis::Alfred::WHATSAPP_WEB_HISTORY_SYNC_MUTEX, channel_id: channel.id)
    expect(lock.lock(key, 1.minute)).to be(true)
    expect { described_class.perform_now }.not_to have_enqueued_job(Channels::WhatsappWeb::HistorySyncJob)
  ensure
    lock&.unlock(key) if key
  end

  it 'skips a proven full empty baseline and does not repeat full imports on each scan' do
    channel = connected_channel
    channel.record_history_sync!(message_count: 0, contact_count: 0, fulfilled_provider_history_synced_at: channel.provider_history_synced_at)
    expect(channel.reload.full_history_baseline_current?).to be(true)
    expect { described_class.perform_now }.not_to have_enqueued_job(Channels::WhatsappWeb::HistorySyncJob)
  end

  it 'recovers a failed old request after its pending lease expires' do
    channel = connected_channel
    channel.request_history_sync!('full', expected_provider_history_synced_at: channel.provider_history_synced_at)
    clear_enqueued_jobs
    expect { described_class.perform_now }.not_to have_enqueued_job(Channels::WhatsappWeb::HistorySyncJob)
    Redis::Alfred.delete(described_class::CURSOR_KEY)
    travel 31.minutes do
      expect { described_class.perform_now }.to have_enqueued_job(Channels::WhatsappWeb::HistorySyncJob)
    end
  end

  it 'keeps the fixed scan bound and moves past the first batch' do
    stub_const('Channels::WhatsappWeb::ReconcileHistoryJob::BATCH_SIZE', 2)
    channels = Array.new(3) { connected_channel }
    expect { described_class.perform_now }.to have_enqueued_job(Channels::WhatsappWeb::HistorySyncJob).exactly(2).times
    clear_enqueued_jobs
    expect { described_class.perform_now }.to have_enqueued_job(Channels::WhatsappWeb::HistorySyncJob).with(
      channels.last.id, 'full', anything
    ).exactly(:once)
  end

  it 'does not let one failed enqueue starve other quiet channels' do
    first = connected_channel
    second = connected_channel
    allow(Channels::WhatsappWeb::HistorySyncJob).to receive(:perform_later).and_wrap_original do |original, *args|
      raise 'Synthetic enqueue failure' if args.first == first.id

      original.call(*args)
    end
    expect { described_class.perform_now }.to have_enqueued_job(Channels::WhatsappWeb::HistorySyncJob).with(second.id, 'full', anything)
    expect(first.reload.history_sync_request_pending?).to be(false)
    expect(second.reload.history_sync_request_pending?).to be(true)
  end

  it 'excludes disconnected, deleting, inactive and not-yet-ready channels' do
    connected_channel(connection_state: 'close')
    deleting = connected_channel
    deleting.inbox.mark_pending_deletion!
    create(:channel_whatsapp_web, connection_state: 'open', lifecycle_state: 'connected')
    inactive = connected_channel
    inactive.account.update!(status: :suspended)
    expect { described_class.perform_now }.not_to have_enqueued_job(Channels::WhatsappWeb::HistorySyncJob)
  end
end
