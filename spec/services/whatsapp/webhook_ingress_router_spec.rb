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
      'widget' => 'https://medelement.one-link.kz/webhooks/meta/whatsapp'
    }
  end

  it 'keeps unmapped WABAs in production' do
    router = described_class.new(payload: payload, rules: {}, targets: targets)

    expect(router.destinations).to eq(['prod'])
  end

  it 'uses a durable exact registry route without consulting static rules' do
    WhatsappWebhookRoute.create!(waba_id: '123456', phone_number_id: '987654', destination: 'widget')
    router = described_class.new(
      payload: payload,
      rules: { '123456:987654' => ['dev'] },
      targets: {}
    )

    expect(router.destinations).to eq(['widget'])
    expect(router.target_url!('widget')).to eq('https://medelement.one-link.kz/webhooks/meta/whatsapp')
  end

  it 'keeps an unregistered phone local even when a stale static exact route exists' do
    router = described_class.new(
      payload: payload,
      rules: { '123456:987654' => ['dev'] },
      targets: targets
    )

    expect(router.destinations).to eq(['prod'])
    expect(router).not_to be_routing_enabled
  end

  it 'canonicalizes the legacy widget target to the MedElement endpoint' do
    legacy_targets = targets.merge('widget' => 'https://widget.one-link.kz/webhooks/meta/whatsapp')
    router = described_class.new(payload: payload, rules: { '123456' => ['widget'] }, targets: legacy_targets)

    expect(router.target_url!('widget')).to eq('https://medelement.one-link.kz/webhooks/meta/whatsapp')
  end

  it 'uses every registered destination for WABA-level events without phone metadata' do
    WhatsappWebhookRoute.create!(waba_id: '123456', phone_number_id: '111', destination: 'dev')
    WhatsappWebhookRoute.create!(waba_id: '123456', phone_number_id: '222', destination: 'widget')
    waba_payload = payload.deep_dup
    waba_payload[:entry][0][:changes][0][:value].delete(:metadata)

    expect(described_class.new(payload: waba_payload, rules: {}, targets: {}).destinations)
      .to contain_exactly('dev', 'widget')
  end

  it 'does not fan out a known unregistered phone to other registry routes in the WABA' do
    WhatsappWebhookRoute.create!(waba_id: '123456', phone_number_id: '111', destination: 'dev')
    WhatsappWebhookRoute.create!(waba_id: '123456', phone_number_id: '222', destination: 'widget')

    expect(described_class.new(payload: payload, rules: {}, targets: {}).destinations).to eq(['prod'])
  end

  it 'falls back to production when the registry lookup is unavailable' do
    allow(WhatsappWebhookRoute).to receive(:for_exact_route).and_raise(ActiveRecord::ConnectionNotEstablished)
    allow(WhatsappWebhookRoute).to receive(:for_waba).and_raise(ActiveRecord::ConnectionNotEstablished)
    allow(Rails.logger).to receive(:error)

    router = described_class.new(payload: payload, rules: { '123456:987654' => ['dev'] }, targets: targets)

    expect(router.destinations).to eq(['prod'])
    expect(Rails.logger).to have_received(:error).with(/processing locally/).at_least(:once)
  end

  it 'keeps a locally owned PROD phone local even when a static exact route exists' do
    allow(WhatsappWebhookRoute).to receive(:local_prod_owner_exists?).with('123456', '987654').and_return(true)
    router = described_class.new(
      payload: payload,
      rules: { '123456:987654' => ['dev'] },
      targets: targets
    )

    expect(router.destinations).to eq(['prod'])
  end

  it 'does not enable batch normalization for a local-only ownership decision' do
    allow(WhatsappWebhookRoute).to receive(:local_prod_owner_exists?).with('123456', '987654').and_return(true)
    router = described_class.new(payload: payload, rules: {}, targets: targets)

    expect(router).not_to be_routing_enabled
  end

  it 'ignores stale static WABA routes' do
    router = described_class.new(
      payload: payload,
      rules: { '123456' => %w[dev widget] },
      targets: targets
    )

    expect(router.destinations).to eq(['prod'])
    expect(router).not_to be_routing_enabled
  end

  it 'ignores stale static exact routes' do
    router = described_class.new(
      payload: payload,
      rules: { '123456' => ['dev'], '123456:987654' => ['widget'] },
      targets: targets
    )

    expect(router.destinations).to eq(['prod'])
  end

  it 'rejects a route to an unknown destination' do
    router = described_class.new(payload: payload, rules: { '123456' => ['unknown'] }, targets: targets)

    expect { router.target_url!('unknown') }
      .to raise_error(described_class::ConfigurationError, /Missing WhatsApp webhook forward target/)
  end

  it 'rejects non-HTTPS forwarding targets' do
    router = described_class.new(
      payload: payload,
      rules: { '123456' => ['dev'] },
      targets: { 'dev' => 'http://127.0.0.1/webhooks/whatsapp' }
    )

    expect { router.target_url!('dev') }
      .to raise_error(described_class::ConfigurationError, /Invalid canonical HTTPS URL/)
  end

  it 'rejects HTTPS forwarding targets outside the canonical destination contract' do
    router = described_class.new(
      payload: payload,
      rules: { '123456' => ['dev'] },
      targets: { 'dev' => 'https://127.0.0.1/webhooks/whatsapp' }
    )

    expect { router.target_url!('dev') }
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
