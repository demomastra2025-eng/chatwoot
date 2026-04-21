require 'rails_helper'
require 'tempfile'

RSpec.describe Telephony::BridgeClient do
  describe '#post' do
    let(:payload) do
      {
        from_number_ref: 'number-ref-1',
        to: 'tel:+77000000000',
        app_ref: 'app-ref-1'
      }
    end
    let(:debug_log_file) { Tempfile.new('telephony-bridge-debug') }

    after do
      debug_log_file.close!
    end

    it 'logs outbound payloads in development for bridge call debugging' do
      allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new('development'))

      stub_request(:post, 'https://bridge.example/telephony/calls/outbound')
        .with(headers: {
                'X-Bridge-Secret' => 'bridge-secret',
                'X-Account-Id' => '1',
                'X-Request-Id' => 'request-123'
              })
        .to_return(
          status: 200,
          body: { call_ref: 'call-123', status: 'ringing' }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      described_class.new(
        base_url: 'https://bridge.example',
        secret: 'bridge-secret',
        account_id: 1,
        request_id: 'request-123',
        debug_log_path: debug_log_file.path
      )
                    .post('/telephony/calls/outbound', payload)

      written_events = File.readlines(debug_log_file.path).map { |line| JSON.parse(line) }

      expect(written_events).to include(
        include(
          'event' => 'telephony_bridge_debug_request',
          'request_id' => 'request-123',
          'path' => '/telephony/calls/outbound',
          'payload' => include('app_ref' => 'app-ref-1')
        ),
        include(
          'event' => 'telephony_bridge_debug_response',
          'request_id' => 'request-123',
          'path' => '/telephony/calls/outbound',
          'status' => 200,
          'body' => include('call_ref' => 'call-123')
        )
      )
    end
  end
end
