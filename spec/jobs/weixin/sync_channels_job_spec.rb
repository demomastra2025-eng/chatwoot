require 'rails_helper'

RSpec.describe Weixin::SyncChannelsJob do
  include ActiveJob::TestHelper

  it 'enqueues on the scheduled jobs queue' do
    expect { described_class.perform_later }
      .to have_enqueued_job(described_class).on_queue('scheduled_jobs')
  end

  it 'syncs credentialed active channels so the gateway restarts its poller after process restarts' do
    channel = create(:channel_weixin, connection_state: 'connected', lifecycle_state: 'connected')
    disconnected_channel = create(:channel_weixin, connection_state: 'disconnected', lifecycle_state: 'disconnected')

    gateway_client = instance_double(Weixin::GatewayClient, sync_channel!: {})

    expect(Weixin::GatewayClient).to receive(:new).with(channel: channel).and_return(gateway_client)
    expect(Weixin::GatewayClient).not_to receive(:new).with(channel: disconnected_channel)

    described_class.perform_now

    expect(channel.reload.last_synced_at).to be_present
    expect(disconnected_channel.reload.last_synced_at).to be_nil
  end

  it 'does not sync channels without credentials, suspended accounts, or deleting inboxes' do
    missing_token = Channel::Weixin.create!(
      account: create(:account),
      display_name: 'Missing Token',
      connection_state: 'connected',
      lifecycle_state: 'connected'
    )
    suspended_account = create(:account, status: :suspended)
    suspended_channel = create(:channel_weixin, account: suspended_account, connection_state: 'connected', lifecycle_state: 'connected')
    deleting_channel = create(:channel_weixin, connection_state: 'connected', lifecycle_state: 'connected')
    deleting_channel.inbox.mark_pending_deletion!
    orphan_channel = create(:channel_weixin, connection_state: 'connected', lifecycle_state: 'connected')
    orphan_channel.inbox.destroy!

    expect(Weixin::GatewayClient).not_to receive(:new).with(channel: missing_token)
    expect(Weixin::GatewayClient).not_to receive(:new).with(channel: suspended_channel)
    expect(Weixin::GatewayClient).not_to receive(:new).with(channel: deleting_channel)
    expect(Weixin::GatewayClient).not_to receive(:new).with(channel: orphan_channel)

    described_class.perform_now
  end

  it 'continues syncing other channels when one channel fails' do
    failed_channel = create(:channel_weixin, connection_state: 'connected', lifecycle_state: 'connected')
    synced_channel = create(:channel_weixin, connection_state: 'connected', lifecycle_state: 'connected')

    failed_client = instance_double(Weixin::GatewayClient)
    synced_client = instance_double(Weixin::GatewayClient, sync_channel!: {})

    allow(Weixin::GatewayClient).to receive(:new).with(channel: failed_channel).and_return(failed_client)
    allow(Weixin::GatewayClient).to receive(:new).with(channel: synced_channel).and_return(synced_client)
    allow(Rails.logger).to receive(:warn)

    expect(failed_client).to receive(:sync_channel!).and_raise(Weixin::GatewayClient::GatewayError, 'gateway unavailable')
    expect(synced_client).to receive(:sync_channel!)

    described_class.perform_now

    expect(synced_channel.reload.last_synced_at).to be_present
    expect(Rails.logger).to have_received(:warn).with(/periodic sync failed/)
  end
end
