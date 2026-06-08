require 'rails_helper'

RSpec.describe Whatsapp::TokenHealthCheckService do
  let(:account) { create(:account) }
  let(:channel) do
    create(
      :channel_whatsapp,
      account: account,
      provider: 'whatsapp_cloud',
      provider_config: {
        'api_key' => 'token-1',
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
      channel.record_provider_authorization_error!(
        error: {
          code: 190,
          type: 'OAuthException',
          message: 'Expired token'
        }
      )

      described_class.new(channel).perform

      expect(channel.reload.provider_config[Channel::Whatsapp::TOKEN_HEALTH_CONFIG_KEY]).to include('status' => 'healthy')
      expect(channel.reauthorization_required?).to be(false)
      expect(channel.provider_config).not_to include('authorization_status')
      expect(channel.provider_config).not_to include('authorization_error')
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
