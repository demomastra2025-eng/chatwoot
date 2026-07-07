require 'rails_helper'

RSpec.describe Telephony::AiVoice::JanusSipRuntimeClient do
  describe '#attach_call' do
    let(:payload) do
      {
        call_ref: 'sipuni:janus:1:raw-call',
        account_id: 42,
        inbox_id: 9,
        conversation_id: 7,
        call_session_id: 456,
        provider: 'sipuni',
        transport: 'janus_sip',
        sip_profile_id: 12,
        janus: {
          session_id: 'janus-session-1',
          handle_id: 'janus-handle-1',
          unique_id: 'janus-unique-1'
        },
        routing: {
          action: 'ai',
          reason: 'pending_conversation_ai_route'
        }
      }
    end

    it 'posts the Janus SIP attach contract to onelink-ai-voice' do
      with_modified_env(ONELINK_AI_VOICE_BASE_URL: 'http://voice.internal:8083', ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
        stub = stub_request(:post, 'http://voice.internal:8083/internal/janus-sip/calls')
               .with(headers: { 'Authorization' => 'Bearer voice-secret', 'Content-Type' => 'application/json' }) do |request|
                 body = JSON.parse(request.body)
                 expect(body).to include(
                   'call_ref' => 'sipuni:janus:1:raw-call',
                   'account_id' => '42',
                   'inbox_id' => '9',
                   'conversation_id' => '7',
                   'call_session_id' => '456',
                   'provider' => 'sipuni',
                   'transport' => 'janus_sip',
                   'sip_profile_id' => '12'
                 )
                 expect(body['janus']).to include(
                   'session_id' => 'janus-session-1',
                   'handle_id' => 'janus-handle-1',
                   'unique_id' => 'janus-unique-1'
                 )
               end
               .to_return(
                 status: 202,
                 body: { status: 'accepted', call_ref: 'sipuni:janus:1:raw-call' }.to_json,
                 headers: { 'Content-Type' => 'application/json' }
               )

        response = described_class.new.attach_call(payload)

        expect(response['status']).to eq('accepted')
        expect(stub).to have_been_requested
      end
    end

    it 'supports an explicit attach path override' do
      with_modified_env(
        ONELINK_AI_VOICE_BASE_URL: 'http://voice.internal:8083/',
        ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret',
        ONELINK_AI_VOICE_JANUS_ATTACH_PATH: 'custom/janus/calls'
      ) do
        stub = stub_request(:post, 'http://voice.internal:8083/custom/janus/calls')
               .to_return(status: 202, body: { status: 'accepted' }.to_json, headers: { 'Content-Type' => 'application/json' })

        described_class.new.attach_call(payload)

        expect(stub).to have_been_requested
      end
    end

    it 'supports the shared voice-agent token alias used by the runtime service' do
      with_modified_env(
        ONELINK_AI_VOICE_BASE_URL: 'http://voice.internal:8083/',
        ONELINK_AI_VOICE_INTERNAL_TOKEN: nil,
        AI_VOICE_INTERNAL_TOKEN: nil,
        VOICE_AGENT_ONELINK_AI_SHARED_SECRET: 'shared-voice-secret'
      ) do
        stub = stub_request(:post, 'http://voice.internal:8083/internal/janus-sip/calls')
               .with(headers: { 'Authorization' => 'Bearer shared-voice-secret' })
               .to_return(status: 202, body: { status: 'accepted' }.to_json, headers: { 'Content-Type' => 'application/json' })

        described_class.new.attach_call(payload)

        expect(stub).to have_been_requested
      end
    end

    it 'fails closed when the runtime base URL is missing' do
      with_modified_env(ONELINK_AI_VOICE_BASE_URL: nil, AI_VOICE_BASE_URL: nil, ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
        expect { described_class.new.attach_call(payload) }.to raise_error(described_class::ConnectionError, /base URL/)
      end
    end

    it 'fails closed when the runtime auth token is missing' do
      with_modified_env(
        ONELINK_AI_VOICE_BASE_URL: 'http://voice.internal:8083',
        ONELINK_AI_VOICE_INTERNAL_TOKEN: nil,
        AI_VOICE_INTERNAL_TOKEN: nil,
        VOICE_AGENT_ONELINK_AI_SHARED_SECRET: nil,
        VOICE_AGENT_INTERNAL_TOKEN: nil,
        ONELINK_INTERNAL_SECRET: nil,
        ONELINK_INTERNAL_TOKEN: nil
      ) do
        expect { described_class.new.attach_call(payload) }.to raise_error(described_class::ConnectionError, /internal token/)
      end
    end

    it 'raises AttachError for non-success responses' do
      with_modified_env(ONELINK_AI_VOICE_BASE_URL: 'http://voice.internal:8083', ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
        stub_request(:post, 'http://voice.internal:8083/internal/janus-sip/calls')
          .to_return(status: 502, body: { error: 'attach_failed' }.to_json, headers: { 'Content-Type' => 'application/json' })

        expect { described_class.new.attach_call(payload) }.to raise_error(described_class::AttachError) { |error|
          expect(error.http_status).to eq(502)
          expect(error.response_body).to include('attach_failed')
        }
      end
    end
  end
end
