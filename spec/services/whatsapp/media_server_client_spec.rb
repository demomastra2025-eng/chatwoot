require 'rails_helper'

RSpec.describe Whatsapp::MediaServerClient do
  describe '#create_runtime_agent' do
    it 'requests a scoped one-time runtime stream contract from media-server' do
      with_modified_env(MEDIA_SERVER_URL: 'https://media.example', MEDIA_SERVER_AUTH_TOKEN: 'secret') do
        stub = stub_request(:post, 'https://media.example/sessions/session-1/runtime-agent')
               .with(
                 headers: { 'Authorization' => 'Bearer secret', 'Content-Type' => 'application/json' }
               ) do |request|
                 body = JSON.parse(request.body)
                 expect(body).to include(
                   'call_ref' => 'whatsapp:wa-call-1',
                   'account_id' => '42',
                   'conversation_id' => '7',
                   'inbox_id' => '9'
                 )
               end
               .to_return(
                 status: 201,
                 body: {
                   runtime_session_id: 'rt-session-1',
                   stream_url: 'ws://media.example/sessions/session-1/runtime-stream',
                   stream_token: 'redacted',
                   codec: 'pcm_s16le'
                 }.to_json,
                 headers: { 'Content-Type' => 'application/json' }
               )

        response = described_class.new.create_runtime_agent(
          'session-1',
          call_ref: 'whatsapp:wa-call-1',
          account_id: 42,
          conversation_id: 7,
          inbox_id: 9
        )

        expect(response['runtime_session_id']).to eq('rt-session-1')
        expect(stub).to have_been_requested
      end
    end
  end

  describe '#set_agent_answer' do
    it 'preserves structured media-leg-closed errors from media-server' do
      with_modified_env(MEDIA_SERVER_URL: 'https://media.example', MEDIA_SERVER_AUTH_TOKEN: 'secret') do
        stub_request(:post, 'https://media.example/sessions/session-1/agent-answer')
          .to_return(
            status: 409,
            body: { code: 'media_leg_closed', error: 'media leg closed: meta_dtls_failed' }.to_json,
            headers: { 'Content-Type' => 'application/json' }
          )

        expect do
          described_class.new.set_agent_answer('session-1', sdp_answer: 'v=0')
        end.to raise_error(described_class::SessionError) { |error|
          expect(error.http_status).to eq(409)
          expect(error.error_code).to eq('media_leg_closed')
          expect(error).to be_media_leg_closed
        }
      end
    end
  end

  describe '#inject_audio' do
    it 'sends sanitized audio source using the media-server API contract' do
      with_modified_env(MEDIA_SERVER_URL: 'https://media.example', MEDIA_SERVER_AUTH_TOKEN: 'secret') do
        stub = stub_request(:post, 'https://media.example/sessions/session-1/inject-audio')
               .with(
                 headers: { 'Authorization' => 'Bearer secret', 'Content-Type' => 'application/json' }
               ) do |request|
                 body = JSON.parse(request.body)
                 expect(body).to include(
                   'source' => 'prompts/welcome.ogg',
                   'mode' => 'mix',
                   'loop' => false,
                   'target' => 'meta'
                 )
                 expect(body).not_to have_key('file_path')
               end
               .to_return(status: 201, body: { id: 'inj-1', status: 'started' }.to_json, headers: { 'Content-Type' => 'application/json' })

        response = described_class.new.inject_audio('session-1', file_path: 'prompts/welcome.ogg', mode: 'mix', target: 'meta')

        expect(response['id']).to eq('inj-1')
        expect(stub).to have_been_requested
      end
    end

    it 'fails closed when the shared auth token is missing' do
      with_modified_env(MEDIA_SERVER_URL: 'https://media.example', MEDIA_SERVER_AUTH_TOKEN: nil) do
        expect do
          described_class.new.inject_audio('session-1', file_path: 'prompts/welcome.ogg')
        end.to raise_error(described_class::ConnectionError, /MEDIA_SERVER_AUTH_TOKEN/)
      end
    end
  end
end
