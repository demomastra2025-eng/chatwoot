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

  describe 'CRUD HTTP verbs' do
    let(:client) do
      described_class.new(
        base_url: 'https://bridge.example/api',
        secret: 'bridge-secret',
        account_id: 42,
        request_id: 'request-456'
      )
    end

    it 'sends PUT payloads through the shared bridge request pipeline' do
      payload = { name: 'trunk-main', metadata: { managed_by: 'onelink' } }

      stub_request(:put, 'https://bridge.example/api/telephony/trunks/trunk-1')
        .with(
          body: payload.to_json,
          headers: {
            'X-Bridge-Secret' => 'bridge-secret',
            'X-Account-Id' => '42',
            'X-Request-Id' => 'request-456'
          }
        )
        .to_return(status: 200, body: { ok: true, trunk_ref: 'trunk-1' }.to_json, headers: { 'Content-Type' => 'application/json' })

      expect(client.put('/telephony/trunks/trunk-1', payload)).to include('ok' => true, 'trunk_ref' => 'trunk-1')
    end

    it 'sends PATCH payloads through the shared bridge request pipeline' do
      payload = { route: { mode: 'app', app_ref: 'voice-runtime-app' } }

      stub_request(:patch, 'https://bridge.example/api/telephony/numbers/number-1/route')
        .with(body: payload.to_json)
        .to_return(status: 200, body: { number_ref: 'number-1', route_updated: true }.to_json, headers: { 'Content-Type' => 'application/json' })

      expect(client.patch('/telephony/numbers/number-1/route', payload)).to include('route_updated' => true)
    end

    it 'sends DELETE requests with optional query params and accepts empty success responses' do
      stub_request(:delete, 'https://bridge.example/api/telephony/agents/agent-1?cascade=false')
        .to_return(status: 204, body: '')

      expect(client.delete('/telephony/agents/agent-1', query: { cascade: false })).to eq({})
    end

    it 'uses the configured gate for mutating verbs when the bridge is missing' do
      client = described_class.new(base_url: '')

      expect { client.put('/telephony/trunks/trunk-1', {}) }.to raise_error(Telephony::Error) { |error|
        expect(error.code).to eq('BRIDGE_NOT_CONFIGURED')
      }
    end
  end
end
