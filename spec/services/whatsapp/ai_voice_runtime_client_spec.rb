require 'rails_helper'

RSpec.describe Whatsapp::AiVoiceRuntimeClient do
  describe '#attach_call' do
    let(:payload) do
      {
        call_ref: 'whatsapp:wa-call-1',
        account_id: 42,
        inbox_id: 9,
        conversation_id: 7,
        whatsapp_call_id: 123,
        call_session_id: 456,
        provider_call_id: 'wa-call-1',
        media_session_id: 'media-session-1',
        runtime_stream: {
          runtime_session_id: 'rt-session-1',
          stream_url: 'ws://media/sessions/media-session-1/runtime-stream?token=runtime-token',
          codec: 'pcm_s16le',
          input_sample_rate: 16_000,
          output_sample_rate: 24_000
        },
        routing: {
          action: 'ai_accept',
          reason: 'conversation_pending_ai_voice_enabled'
        }
      }
    end

    it 'posts the WhatsApp runtime attach contract to onelink-ai-voice' do
      with_modified_env(ONELINK_AI_VOICE_BASE_URL: 'http://voice.internal:8083', ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
        stub = stub_request(:post, 'http://voice.internal:8083/internal/whatsapp-cloud/calls')
               .with(headers: { 'Authorization' => 'Bearer voice-secret', 'Content-Type' => 'application/json' }) do |request|
                 body = JSON.parse(request.body)
                 expect(body).to include(
                   'call_ref' => 'whatsapp:wa-call-1',
                   'account_id' => '42',
                   'inbox_id' => '9',
                   'conversation_id' => '7',
                   'whatsapp_call_id' => '123',
                   'call_session_id' => '456',
                   'provider_call_id' => 'wa-call-1',
                   'media_session_id' => 'media-session-1'
                 )
                 expect(body['runtime_stream']).to include(
                   'runtime_session_id' => 'rt-session-1',
                   'stream_url' => 'ws://media/sessions/media-session-1/runtime-stream?token=runtime-token',
                   'codec' => 'pcm_s16le',
                   'input_sample_rate' => 16_000,
                   'output_sample_rate' => 24_000
                 )
                 expect(body['routing']).to include(
                   'action' => 'ai_accept',
                   'reason' => 'conversation_pending_ai_voice_enabled'
                 )
               end
               .to_return(
                 status: 202,
                 body: { status: 'accepted', runtime_session_id: 'rt-session-1' }.to_json,
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
        ONELINK_AI_VOICE_WHATSAPP_ATTACH_PATH: 'custom/whatsapp/calls'
      ) do
        stub = stub_request(:post, 'http://voice.internal:8083/custom/whatsapp/calls')
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
        AI_VOICE_INTERNAL_TOKEN: nil
      ) do
        expect { described_class.new.attach_call(payload) }.to raise_error(described_class::ConnectionError, /internal token/)
      end
    end

    it 'raises AttachError for non-success responses' do
      with_modified_env(ONELINK_AI_VOICE_BASE_URL: 'http://voice.internal:8083', ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
        stub_request(:post, 'http://voice.internal:8083/internal/whatsapp-cloud/calls')
          .to_return(status: 502, body: { error: 'attach_failed' }.to_json, headers: { 'Content-Type' => 'application/json' })

        expect { described_class.new.attach_call(payload) }.to raise_error(described_class::AttachError) { |error|
          expect(error.http_status).to eq(502)
          expect(error.response_body).to include('attach_failed')
        }
      end
    end
  end
end
