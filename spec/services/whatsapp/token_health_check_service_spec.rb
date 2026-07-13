require 'rails_helper'

RSpec.describe Whatsapp::TokenHealthCheckService do
  let(:account) { create(:account) }
  let(:channel) do
    create(
      :channel_whatsapp,
      account: account,
      provider: 'whatsapp_cloud',
      provider_config: {
        'api_key' => 'token-secret-value',
        'business_account_id' => 'waba-1',
        'phone_number_id' => 'phone-1',
        'source' => 'embedded_signup'
      },
      validate_provider_config: false,
      sync_templates: false
    )
  end

  before do
    allow(Whatsapp::TokenInspectionService).to receive(:new).and_return(token_inspection_service)
  end

  context 'when token health is valid' do
    let(:token_inspection_service) { instance_double(Whatsapp::TokenInspectionService, perform: healthy_token_health) }
    let(:healthy_token_health) do
      {
        'status' => 'healthy',
        'checked_at' => Time.current.iso8601,
        'waba_access' => true,
        'phone_number_access' => true
      }
    end

    it 'stores token health and clears a stale provider authorization error' do
      channel.record_provider_configuration_error!(
        'Expired token',
        code: 190,
        type: 'OAuthException'
      )

      described_class.new(channel).perform

      expect(channel.reload.provider_config[Channel::Whatsapp::TOKEN_HEALTH_CONFIG_KEY]).to include('status' => 'healthy')
      expect(channel.reauthorization_required?).to be(false)
      expect(channel.provider_config).not_to include('authorization_status')
      expect(channel.provider_config).not_to include('authorization_error')
      expect(channel.meta_credential_health).to have_attributes(status: 'healthy', reason: 'healthy')
    end
  end

  context 'when token health requires reauthorization' do
    let(:token_inspection_service) { instance_double(Whatsapp::TokenInspectionService, perform: invalid_token_health) }
    let(:invalid_token_health) do
      {
        'status' => 'invalid',
        'checked_at' => Time.current.iso8601,
        'error' => {
          'code' => 190,
          'type' => 'OAuthException',
          'message' => 'Error validating access token'
        }
      }
    end

    it 'stores token health and prompts reauthorization on the existing channel' do
      described_class.new(channel).perform

      expect(channel.reload.provider_config[Channel::Whatsapp::TOKEN_HEALTH_CONFIG_KEY]).to include('status' => 'invalid')
      expect(channel.reauthorization_required?).to be(true)
      expect(channel.provider_config).to include(
        'authorization_status' => 'reauthorization_required',
        'authorization_error' => hash_including('message' => 'Error validating access token')
      )
      expect(channel.meta_credential_health).to have_attributes(status: 'action_required', reason: 'invalid')
    end
  end

  context 'when provider-returned token health contains credential-bearing fields' do
    let(:one_time_code) { 'one-time-oauth-code' }
    let(:token_inspection_service) do
      instance_double(
        Whatsapp::TokenInspectionService,
        perform: {
          'status' => 'healthy',
          'checked_at' => Time.current.iso8601,
          'oauth_code' => one_time_code,
          'error' => { 'message' => "code=#{one_time_code}", 'refresh_token' => 'provider-refresh-secret' }
        }
      )
    end

    it 'sanitizes the provider config and durable health before persistence' do
      described_class.new(channel).perform

      config_health = channel.reload.provider_config[Channel::Whatsapp::TOKEN_HEALTH_CONFIG_KEY].to_json
      durable_health = channel.meta_credential_health.reload.metadata.to_json
      expect(config_health).not_to include(one_time_code, 'provider-refresh-secret')
      expect(durable_health).not_to include(one_time_code, 'provider-refresh-secret')
    end
  end

  context 'when token inspection raises with credential-bearing text' do
    let(:token_inspection_service) { instance_double(Whatsapp::TokenInspectionService) }
    let(:channel_token) { channel.provider_config['api_key'] }
    let(:raw_error) do
      "failed access_token=query-secret Authorization: Bearer bearer-secret #{channel_token}"
    end

    before do
      allow(token_inspection_service).to receive(:perform).and_raise(ArgumentError, raw_error)
      allow(Rails.logger).to receive(:error)
    end

    it 'redacts logs, provider config, and persisted health metadata' do
      result = described_class.new(channel).perform
      logged_message = nil
      expect(Rails.logger).to have_received(:error) { |message| logged_message = message }

      expect(result.dig('error', 'message')).not_to include('query-secret', 'bearer-secret', channel_token)
      expect(logged_message).not_to include('query-secret', 'bearer-secret', channel_token)
      config = channel.reload.provider_config
      stored_failure = {
        token_health: config[Channel::Whatsapp::TOKEN_HEALTH_CONFIG_KEY],
        authorization_error: config['authorization_error']
      }.to_json
      expect(stored_failure).not_to include('query-secret', 'bearer-secret', channel_token)
      expect(channel.meta_credential_health.reload.metadata.to_json).not_to include('query-secret', 'bearer-secret', channel_token)
    end
  end

  context 'when channel is not WhatsApp Cloud API' do
    let(:token_inspection_service) { instance_double(Whatsapp::TokenInspectionService) }

    it 'does not inspect tokens for 360dialog channels' do
      default_channel = create(:channel_whatsapp, account: account, provider: 'default', validate_provider_config: false, sync_templates: false)

      described_class.new(default_channel).perform

      expect(Whatsapp::TokenInspectionService).not_to have_received(:new)
    end
  end
end
