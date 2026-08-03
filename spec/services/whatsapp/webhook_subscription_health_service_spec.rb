require 'rails_helper'

RSpec.describe Whatsapp::WebhookSubscriptionHealthService do
  let(:channel) do
    channel = create(
      :channel_whatsapp,
      provider: 'whatsapp_cloud',
      sync_templates: false,
      validate_provider_config: false
    )
    allow(channel).to receive(:setup_webhooks).and_return(true)
    channel.update!(
      provider_config: {
        'api_key' => 'token-secret',
        'business_account_id' => 'waba-1',
        'phone_number_id' => 'phone-1',
        'source' => 'embedded_signup'
      }
    )
    channel.reload
  end
  let(:api_client) { instance_double(Whatsapp::FacebookApiClient) }

  before do
    allow(Whatsapp::FacebookApiClient).to receive(:new).with('token-secret').and_return(api_client)
  end

  it 'does not mutate an existing official app subscription' do
    allow(api_client).to receive(:app_subscribed_to_waba?).with('waba-1').and_return(true)

    expect(Whatsapp::WebhookSetupService).not_to receive(:new)

    expect(described_class.new(channel).perform).to eq(:healthy)
  end

  it 'repairs a missing subscription through the guarded callback setup service' do
    allow(api_client).to receive(:app_subscribed_to_waba?).with('waba-1').and_return(false)
    setup_service = instance_double(Whatsapp::WebhookSetupService, register_callback_if_missing: :repaired)

    expect(Whatsapp::WebhookSetupService).to receive(:new) do |target, waba_id, access_token, options|
      expect(target).to eq(channel)
      expect(waba_id).to eq('waba-1')
      expect(access_token).to eq('token-secret')
      expect(options).to include(strict: true, expected_credential_fingerprint: match(/\A[0-9a-f]{64}\z/))
      setup_service
    end

    expect(described_class.new(channel).perform).to eq(:repaired)
    expect(setup_service).to have_received(:register_callback_if_missing)
  end

  it 'does not report a repair when a sibling restored the subscription before the WABA lock was acquired' do
    allow(api_client).to receive(:app_subscribed_to_waba?).with('waba-1').and_return(false)
    setup_service = instance_double(Whatsapp::WebhookSetupService, register_callback_if_missing: :healthy)
    allow(Whatsapp::WebhookSetupService).to receive(:new).and_return(setup_service)

    expect(described_class.new(channel).perform).to eq(:healthy)
  end

  it 'skips an inbox pending deletion without calling Meta' do
    channel.inbox.update!(deleting_at: Time.current)

    expect(Whatsapp::FacebookApiClient).not_to receive(:new)

    expect(described_class.new(channel).perform).to eq(:skipped)
  end

  it 'wraps provider failures in a retryable error without exposing credentials' do
    allow(api_client).to receive(:app_subscribed_to_waba?).and_raise('request failed token-secret')

    expect { described_class.new(channel).perform }
      .to raise_error(described_class::CheckError, /request failed \[FILTERED\]/)
  end
end
