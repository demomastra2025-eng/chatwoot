require 'rails_helper'

RSpec.describe Webhooks::WhatsappForwardJob do
  let(:payload) do
    {
      object: 'whatsapp_business_account',
      entry: [{ id: '123456', changes: [{ field: 'messages', value: { messages: [{ id: 'wamid.1' }] } }] }]
    }
  end
  let(:target_url) { 'https://dev.one-link.kz/webhooks/whatsapp' }
  let(:app_secret) { 'shared-meta-app-secret' }
  let(:forward_secret) { 'shared-internal-forward-secret' }
  let(:response) { Net::HTTPOK.new('1.1', '200', 'OK') }
  let(:http) { instance_double(Net::HTTP) }

  before do
    allow(GlobalConfigService).to receive(:load)
      .with(Whatsapp::WebhookIngressRouter::TARGETS_CONFIG_KEY, '{}')
      .and_return({ 'dev' => target_url })
    allow(GlobalConfigService).to receive(:load).with('WHATSAPP_APP_SECRET', nil).and_return(app_secret)
    allow(GlobalConfigService).to receive(:load)
      .with(Whatsapp::WebhookIngressRouter::FORWARD_SECRET_CONFIG_KEY, nil).and_return(forward_secret)
    allow(Addrinfo).to receive(:getaddrinfo)
      .with('dev.one-link.kz', nil, Socket::AF_UNSPEC, Socket::SOCK_STREAM)
      .and_return([instance_double(Addrinfo, ip_address: '1.1.1.1')])
    allow(Net::HTTP).to receive(:new).with('dev.one-link.kz', 443, nil).and_return(http)
    allow(http).to receive(:ipaddr=)
    allow(http).to receive(:use_ssl=)
    allow(http).to receive(:open_timeout=)
    allow(http).to receive(:read_timeout=)
    allow(http).to receive(:write_timeout=)
    allow(http).to receive(:request).and_return(response)
  end

  it 'uses an isolated queue so unavailable targets cannot starve production inbound jobs' do
    expect(described_class.queue_name).to eq('whatsapp_webhook_forward')
  end

  it 're-signs the atomic payload with the shared Meta App Secret' do
    described_class.new.perform(payload, 'dev')

    body = JSON.generate(payload.deep_stringify_keys)
    expected_signature = "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', app_secret, body)}"
    expected_forwarded_signature = Whatsapp::WebhookIngressRouter.forwarded_signature(
      secret: forward_secret,
      destination: 'dev',
      body: body
    )
    expect(http).to have_received(:ipaddr=).with('1.1.1.1')
    expect(http).to have_received(:request) do |request|
      expect(request).to be_a(Net::HTTP::Post)
      expect(request.path).to eq('/webhooks/whatsapp')
      expect(request.body).to eq(body)
      expect(request.to_hash).to include(
        'content-type' => ['application/json'],
        'x-hub-signature-256' => [expected_signature],
        'x-onelink-webhook-forwarded' => ['1'],
        'x-onelink-webhook-destination' => ['dev'],
        'x-onelink-webhook-forwarded-signature' => [expected_forwarded_signature]
      )
    end
  end

  it 'does not follow redirects from a forwarding target' do
    allow(http).to receive(:request).and_return(Net::HTTPFound.new('1.1', '302', 'Found'))

    expect { described_class.new.perform(payload, 'dev') }
      .to raise_error(described_class::DeliveryError, /target=dev status=302/)
  end

  it 'raises a retryable error without exposing the provider response body' do
    allow(http).to receive(:request).and_return(Net::HTTPServiceUnavailable.new('1.1', '503', 'Unavailable'))

    expect { described_class.new.perform(payload, 'dev') }
      .to raise_error(described_class::DeliveryError, /target=dev status=503/)
  end

  it 'fails closed before delivery when the internal forward secret is missing' do
    allow(GlobalConfigService).to receive(:load)
      .with(Whatsapp::WebhookIngressRouter::FORWARD_SECRET_CONFIG_KEY, nil).and_return(nil)

    expect { described_class.new.perform(payload, 'dev') }
      .to raise_error(described_class::DeliveryError, /forward secret is required/)
    expect(http).not_to have_received(:request)
  end
end
