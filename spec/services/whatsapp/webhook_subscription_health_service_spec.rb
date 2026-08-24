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

  it 'skips a channel that already requires provider reauthorization without calling Meta' do
    channel.update!(
      provider_config: channel.provider_config.merge(
        'authorization_status' => 'reauthorization_required',
        'authorization_error' => { 'code' => 190, 'type' => 'OAuthException' }
      )
    )

    expect(Whatsapp::FacebookApiClient).not_to receive(:new)

    expect(described_class.new(channel).perform).to eq(:skipped)
  end

  it 'records terminal provider authorization errors without retrying the health check' do
    error_payload = {
      'error' => {
        'code' => 190,
        'type' => 'OAuthException',
        'message' => 'The token has expired'
      }
    }
    response = instance_double(HTTParty::Response, parsed_response: error_payload, body: error_payload.to_json, code: 400)
    provider_error = Whatsapp::FacebookApiClient::Error.new('WABA app subscriptions fetch failed', response)
    allow(api_client).to receive(:app_subscribed_to_waba?).and_raise(provider_error)
    allow(channel).to receive(:record_provider_authorization_error_if_current!).and_return(true)

    expect(described_class.new(channel).perform).to eq(:reauthorization_required)
    expect(channel).to have_received(:record_provider_authorization_error_if_current!).with(
      hash_including('code' => 190, 'type' => 'OAuthException'),
      expected_credential_fingerprint: kind_of(String)
    )
  end

  it 'ignores a stale terminal authorization error after the credential rotates' do
    error_payload = {
      'error' => {
        'code' => 190,
        'type' => 'OAuthException',
        'message' => 'The old token has expired'
      }
    }
    response = instance_double(HTTParty::Response, parsed_response: error_payload, body: error_payload.to_json, code: 400)
    provider_error = Whatsapp::FacebookApiClient::Error.new('WABA app subscriptions fetch failed', response)
    allow(api_client).to receive(:app_subscribed_to_waba?) do
      channel.update!(provider_config: channel.provider_config.merge('api_key' => 'rotated-token'))
      raise provider_error
    end

    expect(described_class.new(channel).perform).to eq(:skipped)

    config = channel.reload.provider_config
    expect(config['api_key']).to eq('rotated-token')
    expect(config).not_to include('authorization_status', 'authorization_error')
    expect(channel.reauthorization_required?).to be(false)
  end

  it 'rejects a stale terminal authorization error when the credential rotates during the live health recheck' do
    error_payload = {
      'error' => {
        'code' => 190,
        'type' => 'OAuthException',
        'message' => 'The old token has expired'
      }
    }
    response = instance_double(HTTParty::Response, parsed_response: error_payload, body: error_payload.to_json, code: 400)
    provider_error = Whatsapp::FacebookApiClient::Error.new('WABA app subscriptions fetch failed', response)
    provider_health = instance_double(Meta::AuthorizationHealthCheckService)
    allow(api_client).to receive(:app_subscribed_to_waba?).and_raise(provider_error)
    allow(Meta::AuthorizationHealthCheckService).to receive(:new).with(channel).and_return(provider_health)
    allow(provider_health).to receive(:healthy?) do
      channel.update!(provider_config: channel.provider_config.merge('api_key' => 'rotated-during-health-check'))
      false
    end

    expect(described_class.new(channel).perform).to eq(:skipped)

    config = channel.reload.provider_config
    expect(config['api_key']).to eq('rotated-during-health-check')
    expect(config).not_to include('authorization_status', 'authorization_error')
    expect(channel.reauthorization_required?).to be(false)
  end

  it 'leaves no partial authorization marker when the durable reauthorization lock is busy and succeeds next tick' do
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
    allow(api_client).to receive(:app_subscribed_to_waba?).and_raise(provider_error)
    allow(Meta::AuthorizationHealthCheckService).to receive(:new).with(channel).and_return(provider_health)

    ready = Queue.new
    release = Queue.new
    holder = Thread.new do
      Whatsapp::WabaLock.new("channel-reauthorization-#{channel.id}").with_lock do
        ready << true
        release.pop
      end
    end
    ready.pop

    expect(described_class.new(channel).perform).to eq(:skipped)
    expect(channel.reload.provider_config).not_to include(
      'authorization_status',
      'authorization_error',
      'reauthorization_required'
    )
    expect(channel.reauthorization_required?).to be(false)

    release << true
    holder.value

    expect(described_class.new(channel).perform).to eq(:reauthorization_required)
    expect(channel.reload.provider_config).to include(
      'authorization_status' => 'reauthorization_required',
      'reauthorization_required' => true
    )
  ensure
    release << true if holder&.alive?
    holder&.join
  end

  it 'keeps transient provider errors retryable without recording reauthorization' do
    error_payload = {
      'error' => {
        'code' => 4,
        'type' => 'OAuthException',
        'message' => 'Application request limit reached'
      }
    }
    response = instance_double(HTTParty::Response, parsed_response: error_payload, body: error_payload.to_json, code: 429)
    provider_error = Whatsapp::FacebookApiClient::Error.new('WABA app subscriptions fetch failed', response)
    allow(api_client).to receive(:app_subscribed_to_waba?).and_raise(provider_error)

    expect(channel).not_to receive(:record_provider_authorization_error!)
    expect { described_class.new(channel).perform }
      .to raise_error(described_class::CheckError, /Application request limit reached/)
  end

  it 'wraps provider failures in a retryable error without exposing credentials' do
    allow(api_client).to receive(:app_subscribed_to_waba?).and_raise('request failed token-secret')

    expect { described_class.new(channel).perform }
      .to raise_error(described_class::CheckError, /request failed \[FILTERED\]/)
  end
end
