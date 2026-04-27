require 'rails_helper'

RSpec.describe Whatsapp::MediaServerClient do
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
