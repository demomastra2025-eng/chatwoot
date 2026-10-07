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

  it 'swallows a connection failure so the next tick can retry' do
    connection
    service = instance_double(Telephony::Wazo::CallLogSyncService)
    allow(Telephony::Wazo::CallLogSyncService).to receive(:new).and_return(service)
    allow(service).to receive(:perform).and_raise(Telephony::Error.new(code: 'WAZO_AUTH_FAILED', message: 'Unauthorized'))

    with_modified_env(TELEPHONY_WAZO_CALL_LOG_SYNC_ENABLED: 'true') do
      expect { described_class.perform_now }.not_to raise_error
    end
  end
end
