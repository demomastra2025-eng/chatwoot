require 'rails_helper'

RSpec.describe TelegramCalls::GatewaySoftphoneClient do
  def synthetic_string_session(ip_length = 4)
    packet = [2].pack('C') + ("\x01".b * ip_length) + [443].pack('n') + ('a'.b * 256)
    "1#{Base64.urlsafe_encode64(packet)}"
  end

  let(:worker) do
    { 'worker_id' => 'voice_worker_1', 'api_id' => 123,
      'api_hash' => 'a' * 32, 'string_session' => synthetic_string_session }
  end
  let(:payload) { { leg_id: 'leg-1', metadata: { source: 'test' } } }
  let(:client) { described_class.new(base_url: 'http://gateway.test', token: 'test-token') }

  around do |example|
    with_modified_env('TELEGRAM_CALLS_OPERATOR_WORKER_JSON' => worker.to_json) { example.run }
  end

  it 'adds a validated worker only to the HTTP body without changing the caller payload' do
    original = Marshal.load(Marshal.dump(payload))
    response = instance_double(HTTParty::Response, success?: true, parsed_response: { 'ok' => true })
    expect(HTTParty).to receive(:post) do |url, options|
      expect(url).to eq('http://gateway.test/internal/operator-softphone/legs')
      expect(JSON.parse(options[:body])).to eq(JSON.parse(payload.merge(worker: worker).to_json))
    end.and_return(response)

    expect(client.create_leg!(payload)).to eq('ok' => true)
    expect(payload).to eq(original)
  end

  it 'preserves the old body when the worker setting is blank' do
    with_modified_env('TELEGRAM_CALLS_OPERATOR_WORKER_JSON' => '') do
      response = instance_double(HTTParty::Response, success?: true, parsed_response: {})
      expect(HTTParty).to receive(:post) do |_url, options|
        expect(JSON.parse(options[:body])).to eq(JSON.parse(payload.to_json))
      end.and_return(response)
      client.create_leg!(payload)
    end
  end

  it 'preserves native IPv4 and IPv6 session bytes with canonical padding' do
    [4, 16].each do |ip_length|
      session = synthetic_string_session(ip_length)
      with_modified_env('TELEGRAM_CALLS_OPERATOR_WORKER_JSON' => worker.merge('string_session' => session).to_json) do
        expect(TelegramCalls::Config.operator_worker.fetch('string_session')).to eq(session)
      end
    end
  end

  it 'accepts the native signed int32 upper boundary for api_id' do
    with_modified_env('TELEGRAM_CALLS_OPERATOR_WORKER_JSON' => worker.merge('api_id' => 2_147_483_647).to_json) do
      expect(TelegramCalls::Config.operator_worker.fetch('api_id')).to eq(2_147_483_647)
    end
  end

  it 'rejects malformed, incomplete and untrusted worker settings before HTTP' do
    invalid_sessions = ['x', '1', '1a=', "2#{worker['string_session'].delete_prefix('1')}",
                        "#{worker['string_session']}=", worker['string_session'].delete_suffix('='),
                        "1#{Base64.urlsafe_encode64('a' * 262)}", "1#{Base64.urlsafe_encode64('a' * 274)}"]
    invalid = [' ', '{', worker.except('api_hash').to_json, worker.merge('extra' => 'x').to_json,
               worker.merge('api_id' => '123').to_json, worker.merge('api_hash' => 'bad').to_json,
               worker.merge('worker_id' => '123456789').to_json,
               worker.merge('string_session' => 'bad=inside').to_json,
               worker.merge('string_session' => "secret\nvalue").to_json, 'x' * 8193]
    invalid.concat(invalid_sessions.map { |value| worker.merge('string_session' => value).to_json })
    invalid.concat([0, -1, true, 2_147_483_648].map { |value| worker.merge('api_id' => value).to_json })
    invalid.each do |value|
      with_modified_env('TELEGRAM_CALLS_OPERATOR_WORKER_JSON' => value) do
        expect(HTTParty).not_to receive(:post)
        expect { client.create_leg!(payload) }.to raise_error(Telephony::Error) { |error|
          expect(error.code).to eq('TELEGRAM_WORKER_CONFIG_INVALID')
          expect(error.message).to eq('Telegram voice worker configuration is invalid')
          expect(error.cause).to be_nil
        }
      end
    end
  end

  it 'hides a gateway validation response containing the session' do
    response = instance_double(
      HTTParty::Response, success?: false, parsed_response: { 'detail' => "echo #{worker['string_session']}" }
    )
    allow(HTTParty).to receive(:post).and_return(response)
    expect { client.create_leg!(payload) }.to raise_error(Telephony::Error) { |error|
      expect(error.message).to eq('Telegram voice gateway request failed')
      expect(error.cause).to be_nil
    }
  end

  it 'hides a transport exception containing the session' do
    allow(HTTParty).to receive(:post).and_raise("echo #{worker['string_session']}")
    expect { client.create_leg!(payload) }.to raise_error(Telephony::Error) { |error|
      expect(error.message).to eq('Telegram voice gateway request failed')
      expect(error.cause).to be_nil
    }
  end
end
