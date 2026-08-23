require 'rails_helper'

RSpec.describe Whatsapp::WebhookIngressRouter do
  let(:payload) do
    {
      object: 'whatsapp_business_account',
      entry: [{
        id: '123456',
        changes: [{ value: { metadata: { phone_number_id: '987654' } }, field: 'messages' }]
      }]
    }
  end
  let(:targets) do
    {
      'dev' => 'https://dev.one-link.kz/webhooks/whatsapp',
      'widget' => 'https://widget.one-link.kz/webhooks/meta/whatsapp'
    }
  end

  it 'keeps unmapped WABAs in production' do
    router = described_class.new(payload: payload, rules: {}, targets: targets)

    expect(router.destinations).to eq(['prod'])
  end

  it 'routes a WABA to multiple isolated consumers' do
    router = described_class.new(
      payload: payload,
      rules: { '123456' => %w[dev widget] },
      targets: targets
    )

    expect(router.destinations).to eq(%w[dev widget])
    expect(router.target_url!('dev')).to eq('https://dev.one-link.kz/webhooks/whatsapp')
  end

  it 'prefers an exact WABA and phone-number-id route' do
    router = described_class.new(
      payload: payload,
      rules: { '123456' => ['dev'], '123456:987654' => ['widget'] },
      targets: targets
    )

    expect(router.destinations).to eq(['widget'])
  end

  it 'rejects a route to an unknown destination' do
    router = described_class.new(payload: payload, rules: { '123456' => ['unknown'] }, targets: targets)

    expect { router.destinations }
      .to raise_error(described_class::ConfigurationError, /Missing WhatsApp webhook forward target/)
  end

  it 'rejects non-HTTPS forwarding targets' do
    router = described_class.new(
      payload: payload,
      rules: { '123456' => ['dev'] },
      targets: { 'dev' => 'http://127.0.0.1/webhooks/whatsapp' }
    )

    expect { router.destinations }
      .to raise_error(described_class::ConfigurationError, /Invalid canonical HTTPS URL/)
  end

  it 'rejects HTTPS forwarding targets outside the canonical destination contract' do
    router = described_class.new(
      payload: payload,
      rules: { '123456' => ['dev'] },
      targets: { 'dev' => 'https://127.0.0.1/webhooks/whatsapp' }
    )

    expect { router.destinations }
      .to raise_error(described_class::ConfigurationError, /Invalid canonical HTTPS URL/)
  end

  it 'pins a resolved public address for the canonical target' do
    allow(Addrinfo).to receive(:getaddrinfo)
      .with('dev.one-link.kz', nil, Socket::AF_UNSPEC, Socket::SOCK_STREAM)
      .and_return([instance_double(Addrinfo, ip_address: '1.1.1.1')])
    router = described_class.new(payload: payload, rules: { '123456' => ['dev'] }, targets: targets)

    endpoint = router.target_endpoint!('dev')

    expect(endpoint[:uri].to_s).to eq(targets['dev'])
    expect(endpoint[:ip_address]).to eq(IPAddr.new('1.1.1.1'))
  end

  it 'rejects a canonical target that resolves to a private address' do
    allow(Addrinfo).to receive(:getaddrinfo)
      .with('dev.one-link.kz', nil, Socket::AF_UNSPEC, Socket::SOCK_STREAM)
      .and_return([instance_double(Addrinfo, ip_address: '10.0.0.7')])
    router = described_class.new(payload: payload, rules: { '123456' => ['dev'] }, targets: targets)

    expect { router.target_endpoint!('dev') }
      .to raise_error(described_class::ConfigurationError, /resolved to a disallowed address/)
  end
end
