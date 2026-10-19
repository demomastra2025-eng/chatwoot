# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telephony::BinotelCallHistorySyncJob do
  let(:account) { create(:account) }
  let(:lock_manager) { instance_double(Redis::LockManager, lock: true, unlock: true) }
  let(:sync_service) { instance_double(Telephony::Binotel::CallHistorySyncService, perform: { ok: true }) }
  let(:provider_connection) do
    create(
      :telephony_provider_connection,
      account: account,
      provider_kind: 'binotel',
      host: 'sip53.binotel.com',
      port: 5060,
      transport: 'udp',
      username: 'binotel-line-1'
    )
  end
  let(:channel) do
    create(
      :channel_voice,
      account: account,
      provider: 'binotel',
      phone_number: '+77007585522',
      provider_config: {
        'provider_kind' => 'binotel',
        'provider_connection_id' => provider_connection.id,
        'number_ref' => 'binotel-line-1',
        'binotel_api_key' => 'key-123',
        'binotel_api_secret' => 'secret-456'
      }
    )
  end

  before do
    account.enable_features!('channel_voice')
    allow(Redis::LockManager).to receive(:new).and_return(lock_manager)
    allow(Telephony::Binotel::CallHistorySyncService).to receive(:new).and_return(sync_service)
  end

  it 'fans out per-channel jobs when invoked without channel_id' do
    channel
    expect { described_class.perform_now }
      .to have_enqueued_job(described_class).with(channel_id: channel.id)
    expect(Telephony::Binotel::CallHistorySyncService).not_to have_received(:new)
  end

  it 'syncs a single channel under a per-channel Redis mutex lock' do
    described_class.perform_now(channel_id: channel.id)

    expect(lock_manager).to have_received(:lock).with(
      "TELEPHONY::BINOTEL_CALL_HISTORY_SYNC_MUTEX::#{channel.id}",
      90.seconds
    )
    expect(Telephony::Binotel::CallHistorySyncService).to have_received(:new).with(channel: channel)
    expect(sync_service).to have_received(:perform)
    expect(lock_manager).to have_received(:unlock).with(
      "TELEPHONY::BINOTEL_CALL_HISTORY_SYNC_MUTEX::#{channel.id}"
    )
  end

  it 'skips syncing when the per-channel mutex is already held' do
    allow(lock_manager).to receive(:lock).and_return(false)

    described_class.perform_now(channel_id: channel.id)

    expect(Telephony::Binotel::CallHistorySyncService).not_to have_received(:new)
  end
end
