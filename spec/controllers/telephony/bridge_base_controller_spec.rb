require 'rails_helper'

RSpec.describe Telephony::BridgeBaseController, type: :controller do
  describe '#log_telephony_debug' do
    it 'logs only fingerprinted allowlisted request and response fields without exception messages' do
      request = instance_double(
        ActionDispatch::Request,
        request_id: 'request-1',
        method: 'POST',
        path: '/telephony/bridge/events',
        headers: { 'X-Account-Id' => '42' }
      )
      allow(controller).to receive(:request).and_return(request)

      expect(Telephony::DebugLogger).to receive(:log) do |event:, payload:|
        call_ref_digest = "sha256:#{Digest::SHA256.hexdigest('call-1').first(16)}"
        number_ref_digest = "sha256:#{Digest::SHA256.hexdigest('number-raw-0009').first(16)}"
        app_ref_digest = "sha256:#{Digest::SHA256.hexdigest('x' * 300).first(16)}"
        expect(event).to eq('telephony_test')
        expect(payload).to include(
          request_id: 'request-1',
          account_id: '42',
          call_ref: call_ref_digest,
          number_ref: number_ref_digest,
          request_payload: {
            'call_ref' => call_ref_digest,
            'number_ref' => number_ref_digest,
            'status' => 'ringing'
          },
          response_payload: { 'action' => 'app', 'app_ref' => app_ref_digest, 'status' => 'accepted' },
          error_class: 'RuntimeError'
        )
        expect(payload.to_json).not_to include(
          'number-raw-0009',
          'caller-number-raw',
          'call-1',
          'capability-secret',
          'access-secret',
          'nested-secret',
          'customer transcript',
          'provider-secret'
        )
      end

      controller.send(
        :log_telephony_debug,
        event: 'telephony_test',
        payload: {
          call_ref: 'call-1',
          number_ref: 'number-raw-0009',
          status: 'ringing',
          caller_number: 'caller-number-raw',
          tool_capability: 'capability-secret',
          access_token: 'access-secret',
          transcript: 'customer transcript'
        },
        response_payload: {
          action: 'app',
          app_ref: 'x' * 300,
          event: { access_token: 'nested-secret' },
          status: 'accepted',
          provider_token: 'provider-secret'
        },
        error: RuntimeError.new('provider-secret')
      )
    end
  end
end
