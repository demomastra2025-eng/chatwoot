# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telephony::Wazo::CallLogSyncJob do
  let(:connection) do
    create(:telephony_provider_connection, provider_kind: 'wazo', status: 'active',
                                           metadata: { wazo_call_log_sync_enabled: true,
                                                       wazo_call_log_sync_operator_extension: '101' })
  end

  it 'does nothing when the global flag is off' do
    connection
    with_modified_env(TELEPHONY_WAZO_CALL_LOG_SYNC_ENABLED: nil) do
      expect(Telephony::Wazo::CallLogSyncService).not_to receive(:new)
      described_class.perform_now
    end
  end

  it 'fans out per-connection jobs when called without connection_id' do
    connection
    with_modified_env(TELEPHONY_WAZO_CALL_LOG_SYNC_ENABLED: 'true') do
      expect do
        described_class.perform_now
      end.to have_enqueued_job(described_class).with(connection_id: connection.id)
    end
  end

  it 'runs CallLogSyncService under a per-connection Redis mutex lock when connection_id is given' do
    lock_manager = instance_double(Redis::LockManager, lock: true, unlock: true)
    allow(Redis::LockManager).to receive(:new).and_return(lock_manager)
    service = instance_double(Telephony::Wazo::CallLogSyncService, perform: true)
    allow(Telephony::Wazo::CallLogSyncService).to receive(:new).with(connection: connection).and_return(service)

    with_modified_env(TELEPHONY_WAZO_CALL_LOG_SYNC_ENABLED: 'true') do
      described_class.perform_now(connection_id: connection.id)
    end

    expect(lock_manager).to have_received(:lock).with(
      "TELEPHONY::WAZO_CALL_LOG_SYNC_MUTEX::#{connection.id}", 90.seconds
    )
    expect(service).to have_received(:perform).once
    expect(lock_manager).to have_received(:unlock).with(
      "TELEPHONY::WAZO_CALL_LOG_SYNC_MUTEX::#{connection.id}"
    )
  end

  it 'skips execution when another worker holds the per-connection Redis lock' do
    lock_manager = instance_double(Redis::LockManager, lock: false)
    allow(Redis::LockManager).to receive(:new).and_return(lock_manager)

    with_modified_env(TELEPHONY_WAZO_CALL_LOG_SYNC_ENABLED: 'true') do
      expect(Telephony::Wazo::CallLogSyncService).not_to receive(:new)
      described_class.perform_now(connection_id: connection.id)
    end
  end

  it 'swallows a connection failure so the next tick can retry' do
    connection
    service = instance_double(Telephony::Wazo::CallLogSyncService)
    allow(Telephony::Wazo::CallLogSyncService).to receive(:new).and_return(service)
    allow(service).to receive(:perform).and_raise(Telephony::Error.new(code: 'WAZO_AUTH_FAILED', message: 'Unauthorized'))

    with_modified_env(TELEPHONY_WAZO_CALL_LOG_SYNC_ENABLED: 'true') do
      expect { described_class.perform_now(connection_id: connection.id) }.not_to raise_error
    end
  end
end
