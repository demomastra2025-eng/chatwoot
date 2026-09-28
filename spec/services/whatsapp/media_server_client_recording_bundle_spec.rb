require 'rails_helper'

RSpec.describe Whatsapp::MediaServerClient do
  let(:client) { described_class.new }
  let(:error_class) { Whatsapp::MediaServerClient::SessionError }

  around do |example|
    with_modified_env(MEDIA_SERVER_URL: 'https://media.example.test', MEDIA_SERVER_AUTH_TOKEN: 'synthetic-token') { example.run }
  end

  it 'downloads exact manifest bytes through a scoped authenticated URL' do
    body = '{"version":1,"state":"final"}'
    stub = stub_request(:get, 'https://media.example.test/sessions/session_test/recording-manifest')
           .with(query: { account_id: '42', call_id: 'call_test' }, headers: { 'Authorization' => 'Bearer synthetic-token' })
           .to_return(status: 200, body: body)

    expect(client.download_recording_manifest('session_test', account_id: 42, call_id: 'call_test')).to eq(body)
    expect(stub).to have_been_requested
  end

  it 'downloads an allowlisted artifact without using a supplied external path' do
    stub = stub_request(:get, 'https://media.example.test/sessions/session_test/recording-artifacts/track_000001')
           .with(query: { account_id: '42', call_id: 'call_test' }).to_return(status: 200, body: 'capture')

    expect(client.download_recording_artifact('session_test', 'track_000001', account_id: 42, call_id: 'call_test')).to eq('capture')
    expect(stub).to have_been_requested
  end

  it 'rejects traversal and URL-like IDs before sending a request' do
    expect { client.download_recording_manifest('../foreign', account_id: 42, call_id: 'call_test') }.to raise_error(error_class)
    expect do
      client.download_recording_artifact('session_test', 'https://example.test', account_id: 42, call_id: 'call_test')
    end.to raise_error(error_class)
    expect { client.download_recording_artifact('session_test', '../foreign', account_id: 42, call_id: 'call_test') }.to raise_error(error_class)
  end

  it 'preserves unavailable status for the importer retry gate' do
    stub_request(:get, 'https://media.example.test/sessions/session_test/recording-manifest')
      .with(query: { account_id: '42', call_id: 'call_test' }).to_return(status: 404, body: 'missing')

    expect do
      client.download_recording_manifest('session_test', account_id: 42, call_id: 'call_test')
    end.to raise_error(error_class) { |error| expect(error.http_status).to eq(404) }
  end
end
