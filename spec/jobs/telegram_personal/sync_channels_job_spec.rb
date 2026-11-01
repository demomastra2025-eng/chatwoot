require 'rails_helper'

RSpec.describe TelegramPersonal::SyncChannelsJob do
  include ActiveJob::TestHelper

  it 'enqueues on the scheduled jobs queue' do
    expect { described_class.perform_later }
      .to have_enqueued_job(described_class).on_queue('scheduled_jobs')
  end

  it 'syncs authorized active channels and updates last_synced_at without touching unchanged channel state' do
    channel = create(
      :channel_telegram_personal,
      connection_state: 'connected',
      lifecycle_state: 'connected',
      string_session: '1BVtsOK8Bu-session'
    )
    previous_inbox_updated_at = channel.inbox.updated_at

    gateway_client = instance_double(
      TelegramPersonal::GatewayClient,
      sync_channel!: {
        channel: {
          connection_state: 'connected',
          lifecycle_state: 'connected',
          last_error: nil,
          string_session: '1BVtsOK8Bu-session',
          runtime_state: channel.runtime_state_payload
        }
      }
    )

    expect(TelegramPersonal::GatewayClient).to receive(:new).with(channel: channel).and_return(gateway_client)

    described_class.perform_now

    expect(channel.reload.last_synced_at).to be_present
    expect(channel.inbox.reload.updated_at).to eq(previous_inbox_updated_at)
  end

  it 'persists runtime state transitions such as revoked sessions returned by the gateway' do
    channel = create(
      :channel_telegram_personal,
      connection_state: 'connected',
      lifecycle_state: 'connected',
      string_session: '1BVtsOK8Bu-session'
    )

    gateway_client = instance_double(
      TelegramPersonal::GatewayClient,
      sync_channel!: {
        channel: {
          connection_state: 'auth_required',
          lifecycle_state: 'disconnected',
          last_error: 'Telegram session was revoked or expired. Please reconnect.',
          runtime_state: { history_sync_state: 'cancelled' }
        }
      }
    )

    expect(TelegramPersonal::GatewayClient).to receive(:new).with(channel: channel).and_return(gateway_client)

    described_class.perform_now

    channel.reload
    expect(channel.connection_state).to eq('auth_required')
    expect(channel.lifecycle_state).to eq('disconnected')
    expect(channel.last_error).to include('revoked')
    expect(channel.runtime_state['history_sync_state']).to eq('cancelled')
  end

  it 'skips revoked, pending-auth, disconnected, blank-session, suspended, deleting, and orphan channels' do
    revoked_channel = create(:channel_telegram_personal, connection_state: 'auth_required', lifecycle_state: 'disconnected', string_session: 's1')
    pending_channel = create(:channel_telegram_personal, connection_state: 'disconnected', lifecycle_state: 'pending_auth', string_session: 's2')
    code_sent_channel = create(:channel_telegram_personal, connection_state: 'connecting', lifecycle_state: 'code_sent', string_session: 's3')
    blank_session_channel = create(:channel_telegram_personal, connection_state: 'connected', lifecycle_state: 'connected', string_session: nil)
    suspended_account = create(:account, status: :suspended)
    suspended_channel = create(:channel_telegram_personal, account: suspended_account, connection_state: 'connected', lifecycle_state: 'connected',
                                                           string_session: 's4')
    deleting_channel = create(:channel_telegram_personal, connection_state: 'connected', lifecycle_state: 'connected', string_session: 's5')
    deleting_channel.inbox.mark_pending_deletion!
    orphan_channel = create(:channel_telegram_personal, connection_state: 'connected', lifecycle_state: 'connected', string_session: 's6')
    orphan_channel.inbox.destroy!

    [revoked_channel, pending_channel, code_sent_channel, blank_session_channel, suspended_channel, deleting_channel, orphan_channel].each do |ch|
      expect(TelegramPersonal::GatewayClient).not_to receive(:new).with(channel: ch)
    end

    described_class.perform_now
  end

  it 'continues syncing remaining channels when one channel raises an error' do
    failed_channel = create(
      :channel_telegram_personal,
      connection_state: 'connected',
      lifecycle_state: 'connected',
      string_session: '1BVtsOK8Bu-fail'
    )
    healthy_channel = create(
      :channel_telegram_personal,
      connection_state: 'connected',
      lifecycle_state: 'connected',
      string_session: '1BVtsOK8Bu-ok'
    )

    failed_client = instance_double(TelegramPersonal::GatewayClient)
    healthy_client = instance_double(TelegramPersonal::GatewayClient, sync_channel!: {})

    allow(TelegramPersonal::GatewayClient).to receive(:new).with(channel: failed_channel).and_return(failed_client)
    allow(TelegramPersonal::GatewayClient).to receive(:new).with(channel: healthy_channel).and_return(healthy_client)
    allow(Rails.logger).to receive(:warn)

    expect(failed_client).to receive(:sync_channel!).and_raise(TelegramPersonal::GatewayClient::GatewayError, 'gateway unavailable')
    expect(healthy_client).to receive(:sync_channel!)

    described_class.perform_now

    expect(healthy_channel.reload.last_synced_at).to be_present
    expect(Rails.logger).to have_received(:warn).with(/periodic sync failed/)
  end
end
