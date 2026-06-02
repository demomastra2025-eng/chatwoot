# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Voice::Provider::Sipuni::Adapter do
  subject(:adapter) { described_class.new(channel) }

  let(:channel) do
    instance_double(
      Channel::Voice,
      phone_number: ['+7', '727', '1234567'].join,
      provider_config_hash: provider_config
    )
  end
  let(:provider_config) do
    {
      account_number: '123456',
      integration_secret: 'top-secret',
      default_internal_number: '100',
      reverse: '1',
      antiaon: '0'
    }
  end
  let(:normalized_phone) { %w[7 701 1234567].join }
  let(:outbound_phone) { ['+7 ', '(701) ', '123-45-67'].join }

  describe '#initiate_call' do
    it 'creates a Sipuni callback request and returns a sanitized outbound call payload' do
      expected_body = {
        'antiaon' => '0',
        'phone' => normalized_phone,
        'reverse' => '1',
        'sipnumber' => '100',
        'user' => '123456',
        'hash' => Digest::MD5.hexdigest(['0', normalized_phone, '1', '100', '123456', 'top-secret'].join('+'))
      }
      stub_request(:post, described_class::CALL_NUMBER_URL)
        .with(body: expected_body)
        .to_return(
          status: 200,
          body: { status: 'ringing', result: { callbackId: 'sipuni-order-1' }, secret: 'do-not-leak' }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      result = adapter.initiate_call(to: outbound_phone, conference_sid: 'conf-1', agent_id: 11)

      expect(result).to include(
        provider: 'sipuni',
        call_sid: 'sipuni-order-1',
        status: 'ringing',
        call_direction: 'outbound',
        requires_agent_join: false,
        conference_sid: 'conf-1',
        agent_id: 11
      )
      expect(result[:sipuni_response]).not_to have_key('secret')
    end

    it 'normalizes Kazakhstan trunk-prefix outbound phone numbers' do
      stub_request(:post, described_class::CALL_NUMBER_URL)
        .with(body: hash_including('phone' => normalized_phone))
        .to_return(
          status: 200,
          body: { callbackId: 'sipuni-order-2' }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      result = adapter.initiate_call(to: %w[8 701 1234567].join)

      expect(result[:call_sid]).to eq('sipuni-order-2')
    end

    it 'fails closed when required Sipuni callback configuration is missing' do
      provider_config.delete(:integration_secret)

      expect { adapter.initiate_call(to: outbound_phone) }.to raise_error(Telephony::Error) { |error|
        expect(error.code).to eq('SIPUNI_OUTBOUND_NOT_CONFIGURED')
        expect(error.status).to eq(:unprocessable_content)
        expect(error.details[:missing]).to include('integration_secret')
      }
    end

    it 'fails closed when Sipuni rejects the callback request' do
      stub_request(:post, described_class::CALL_NUMBER_URL)
        .to_return(
          status: 200,
          body: { status: 'error', error: 'bad hash', secret: 'do-not-leak' }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      expect { adapter.initiate_call(to: outbound_phone) }.to raise_error(Telephony::Error) { |error|
        expect(error.code).to eq('SIPUNI_OUTBOUND_FAILED')
        expect(error.status).to eq(:bad_gateway)
        expect(error.details[:response]).not_to have_key('secret')
      }
    end
  end
end
