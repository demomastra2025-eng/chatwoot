require 'rails_helper'

RSpec.describe Telephony::VoiceCoreClient do
  let(:client) { described_class.new }
  let(:job_id) { 'a' * 32 }
  let(:request_args) { { account_id: 101, job_id: job_id, audio_filename: 'audio.wav', channel_map: { '0' => 'operator', '1' => 'client' } } }
  let(:payload) do
    { schema: described_class::RESPONSE_SCHEMA, account_id: 101, job_id: job_id, text: 'Тест',
      dialogue_turns: [{ speaker: 'operator', channel: 0, start_sec: 0.2, end_sec: 1.4, text: 'Тест' }],
      language: 'ru', duration_sec: 2.0, channels: 2, channel_status: 'mapped', model_version: Telephony::VoiceCoreClient::APPROVED_MANIFEST_SHA256 }
  end

  around do |example|
    with_modified_env('ONELINK_VOICECORE_URL' => 'http://127.0.0.1:8095', 'ONELINK_VOICECORE_TOKEN' => 't' * 32) { example.run }
  end

  def stub_response(body = payload, status: 200)
    stub_request(:post, 'http://127.0.0.1:8095/transcribe')
      .with(headers: { 'Authorization' => "Bearer #{'t' * 32}" })
      .to_return(status: status, body: body.to_json, headers: { 'Content-Type' => 'application/json' })
  end

  it 'requires an exact deployment switch and explicit positive account allowlist' do
    account = instance_double(Account, id: 101)
    with_modified_env('ONELINK_VOICECORE_ENABLED' => nil, 'ONELINK_VOICECORE_ACCOUNT_IDS' => '101') do
      expect(described_class.selected_for?(account)).to be(false)
    end
    with_modified_env('ONELINK_VOICECORE_ENABLED' => 'true', 'ONELINK_VOICECORE_ACCOUNT_IDS' => '101,102') do
      expect(described_class.selected_for?(account)).to be(true)
      expect(described_class.selected_for?(instance_double(Account, id: 103))).to be(false)
    end
    with_modified_env('ONELINK_VOICECORE_ENABLED' => 'true', 'ONELINK_VOICECORE_ACCOUNT_IDS' => '101,garbage') do
      expect { described_class.selected_for?(account) }.to raise_error(described_class::Error)
    end
  end

  it 'posts only the account-bound spool descriptor and preserves precise turns' do
    request = stub_response
    result = client.transcribe(**request_args)
    expect(result['dialogue_turns'].first).to include('start_sec' => 0.2, 'end_sec' => 1.4)
    expect(request).to have_been_requested.once
    expected = request_args.stringify_keys.merge('schema' => described_class::REQUEST_SCHEMA, 'is_phone_call' => true)
    matcher = have_requested(:post, 'http://127.0.0.1:8095/transcribe').with { |sent| JSON.parse(sent.body) == expected }
    expect(WebMock).to matcher
  end

  it 'sends an explicit boolean false for a voice note and refuses string booleans' do
    request = stub_response
    client.transcribe(**request_args, is_phone_call: false)
    expect(request).to have_been_requested.once
    matcher = have_requested(:post, 'http://127.0.0.1:8095/transcribe').with { |sent| JSON.parse(sent.body)['is_phone_call'] == false }
    expect(WebMock).to matcher
    expect { client.transcribe(**request_args, is_phone_call: 'false') }.to raise_error(described_class::Error)
  end

  it 'accepts AAC and WebM descriptors and rejects disguised paths or URLs' do
    request = stub_response
    %w[audio.aac audio.webm].each { |filename| client.transcribe(**request_args, audio_filename: filename, is_phone_call: false) }
    expect(request).to have_been_requested.twice
    %w[audio.webm/../audio.wav audio.aac?source=http://example.test/audio.aac].each do |filename|
      expect { client.transcribe(**request_args, audio_filename: filename) }.to raise_error(described_class::Error)
    end
  end

  it 'rejects a foreign account or job in an otherwise successful response' do
    stub_response(payload.merge(account_id: 102))
    expect { client.transcribe(**request_args) }.to raise_error(described_class::Error) { |error| expect(error.code).to eq('invalid_response') }
    stub_response(payload.merge(job_id: 'c' * 32))
    expect { client.transcribe(**request_args) }.to raise_error(described_class::Error)
  end

  it 'rejects any other well-formed manifest without making the failure retryable' do
    stub_response(payload.merge(model_version: 'b' * 64))
    expect { client.transcribe(**request_args) }.to raise_error(described_class::Error) do |error|
      expect(error.code).to eq('unapproved_manifest')
      expect(error.retryable).to be(false)
    end
  end

  it 'rejects fabricated roles, nonfinite/out of range turns, and unrecognized response fields' do
    invalids = [payload.deep_merge(dialogue_turns: [payload[:dialogue_turns].first.merge(speaker: 'client')]),
                payload.deep_merge(dialogue_turns: [payload[:dialogue_turns].first.merge(end_sec: 3)]),
                payload.merge(channels: 3), payload.merge(extra: true), payload.merge(duration_sec: '2')]
    invalids.each do |body|
      stub_response(body)
      expect { client.transcribe(**request_args) }.to raise_error(described_class::Error)
    end
  end

  it 'accepts mono unknown turns and silence without inventing a role or a transcript' do
    mono = payload.merge(channels: 1, channel_status: 'mono', dialogue_turns: [payload[:dialogue_turns].first.merge(speaker: 'unknown')])
    stub_response(mono)
    expect(client.transcribe(**request_args, channel_map: {})['dialogue_turns'].first['speaker']).to eq('unknown')
    stub_response(mono.merge(text: '', dialogue_turns: [], language: 'unknown'))
    expect(client.transcribe(**request_args, channel_map: {})['text']).to eq('')
  end

  it 'bounds response bytes and never follows redirects' do
    stub_request(:post, 'http://127.0.0.1:8095/transcribe').to_return(
      status: 200, body: 'x', headers: { 'Content-Type' => 'application/json', 'Content-Length' => described_class::MAX_RESPONSE_BYTES + 1 }
    )
    expect { client.transcribe(**request_args) }.to raise_error(described_class::Error) { |error| expect(error.code).to eq('response_too_large') }
    stub_response({}, status: 302)
    expect { client.transcribe(**request_args) }.to raise_error(described_class::Error) { |error| expect(error.retryable).to be(false) }
  end

  it 'marks busy or timeout responses retryable but authentication failures terminal' do
    stub_response({}, status: 503)
    expect { client.transcribe(**request_args) }.to raise_error(described_class::Error) { |error| expect(error.retryable).to be(true) }
    stub_response({}, status: 401)
    expect { client.transcribe(**request_args) }.to raise_error(described_class::Error) { |error| expect(error.retryable).to be(false) }
  end

  it 'refuses remote URLs, URL credentials, weak tokens and arbitrary filenames before networking' do
    %w[http://example.test:8095 http://127.0.0.1:8095/other http://user:pass@127.0.0.1:8095].each do |url|
      with_modified_env('ONELINK_VOICECORE_URL' => url) do
        expect { client.transcribe(**request_args) }.to raise_error(described_class::Error)
      end
    end
    with_modified_env('ONELINK_VOICECORE_TOKEN' => 'short') do
      expect { client.transcribe(**request_args) }.to raise_error(described_class::Error)
    end
    expect { client.transcribe(**request_args, audio_filename: '../audio.wav') }.to raise_error(described_class::Error)
  end
end
