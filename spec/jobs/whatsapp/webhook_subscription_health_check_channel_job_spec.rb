require 'rails_helper'

RSpec.describe Whatsapp::WebhookSubscriptionHealthCheckChannelJob do
  let(:health_service) { instance_double(Whatsapp::WebhookSubscriptionHealthService, perform: :healthy) }

  before do
    allow(Whatsapp::WebhookSubscriptionHealthService).to receive(:new).and_return(health_service)
  end

  it 'checks an active WhatsApp Cloud channel' do
    channel = create(:channel_whatsapp, provider: 'whatsapp_cloud', sync_templates: false, validate_provider_config: false)

    described_class.perform_now(channel.id)

    expect(Whatsapp::WebhookSubscriptionHealthService).to have_received(:new).with(channel)
    expect(health_service).to have_received(:perform)
  end

  it 'persists terminal authorization state without raising a retryable job error' do
    channel = create(
      :channel_whatsapp,
      provider: 'whatsapp_cloud',
      sync_templates: false,
      validate_provider_config: false
    )
    channel.update!(
      provider_config: channel.provider_config.merge(
        'api_key' => 'expired-token',
        'business_account_id' => 'waba-1'
      )
    )
    api_client = instance_double(Whatsapp::FacebookApiClient)
    error_payload = {
      'error' => {
        'code' => 190,
        'type' => 'OAuthException',
        'message' => 'The token has expired'
      }
    }
    response = instance_double(HTTParty::Response, parsed_response: error_payload, body: error_payload.to_json, code: 400)
    provider_error = Whatsapp::FacebookApiClient::Error.new('WABA app subscriptions fetch failed', response)
    provider_health = instance_double(Meta::AuthorizationHealthCheckService, healthy?: false)
    allow(Whatsapp::WebhookSubscriptionHealthService).to receive(:new).and_call_original
    allow(Whatsapp::FacebookApiClient).to receive(:new).with('expired-token').and_return(api_client)
    allow(api_client).to receive(:app_subscribed_to_waba?).with('waba-1').and_raise(provider_error)
    allow(Meta::AuthorizationHealthCheckService).to receive(:new).and_return(provider_health)

    expect { described_class.perform_now(channel.id) }.not_to raise_error

    expect(channel.reload.provider_config).to include(
      'authorization_status' => 'reauthorization_required',
      'authorization_error' => hash_including('code' => 190, 'type' => 'OAuthException')
    )
    expect(channel.reauthorization_required?).to be(true)
  end

  it 'ignores non-Cloud and suspended-account channels' do
    default_channel = create(:channel_whatsapp, provider: 'default', sync_templates: false, validate_provider_config: false)
    suspended_channel = create(
      :channel_whatsapp,
      provider: 'whatsapp_cloud',
      account: create(:account, status: 'suspended'),
      sync_templates: false,
      validate_provider_config: false
    )

    described_class.perform_now(default_channel.id)
    described_class.perform_now(suspended_channel.id)

    expect(Whatsapp::WebhookSubscriptionHealthService).not_to have_received(:new)
  end
end
