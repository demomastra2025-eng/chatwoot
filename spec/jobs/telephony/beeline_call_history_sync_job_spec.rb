# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telephony::BeelineCallHistorySyncJob do
  let(:account) { create(:account) }
  let(:lock_manager) { instance_double(Redis::LockManager, lock: true, unlock: true) }
  let(:sync_service) { instance_double(Telephony::Beeline::CallHistorySyncService, perform: { ok: true }) }
  let(:provider_connection) do
    create(
      :telephony_provider_connection,
      account: account,
      provider_kind: 'beeline',
      host: 'cloudpbx.beeline.kz',
      port: 5060,
      transport: 'udp',
      username: 'beeline-line-1'
    )
  end
  let(:channel) do
    create(
      :channel_voice,
      account: account,
      provider: 'beeline',
      phone_number: '+77059001122',
      provider_config: {
        'provider_kind' => 'beeline',
        'provider_connection_id' => provider_connection.id,
        'number_ref' => 'beeline-line-1',
        'beeline_api_token' => 'token-123'
      }
    )
  end

  before do
    account.enable_features!('channel_voice')
    allow(Redis::LockManager).to receive(:new).and_return(lock_manager)
    allow(Telephony::Beeline::CallHistorySyncService).to receive(:new).and_return(sync_service)
  end

  it 'fans out per-channel jobs when invoked without channel_id' do
    channel
    expect { described_class.perform_now }
      .to have_enqueued_job(described_class).with(channel_id: channel.id, subscribe_webhook: :auto)
    expect(Telephony::Beeline::CallHistorySyncService).not_to have_received(:new)
  end

  it 'syncs a single channel under a per-channel Redis mutex lock' do
    described_class.perform_now(channel_id: channel.id, subscribe_webhook: true)

    expect(lock_manager).to have_received(:lock).with(
      "TELEPHONY::BEELINE_CALL_HISTORY_SYNC_MUTEX::#{channel.id}",
      90.seconds
    )
    expect(Telephony::Beeline::CallHistorySyncService).to have_received(:new).with(
      channel: channel,
      subscribe_webhook: true
    )
    expect(sync_service).to have_received(:perform)
    expect(lock_manager).to have_received(:unlock).with(
      "TELEPHONY::BEELINE_CALL_HISTORY_SYNC_MUTEX::#{channel.id}"
    )
  end

  it 'skips syncing when the per-channel mutex is already held' do
    allow(lock_manager).to receive(:lock).and_return(false)

    described_class.perform_now(channel_id: channel.id)

    expect(Telephony::Beeline::CallHistorySyncService).not_to have_received(:new)
  end
end
