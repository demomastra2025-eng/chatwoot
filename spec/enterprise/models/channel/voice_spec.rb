# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Channel::Voice do
  let(:twiml_app_sid) { 'AP1234567890abcdef' }
  let(:channel) { create(:channel_voice) }

  before do
    allow(Twilio::VoiceWebhookSetupService).to receive(:new).and_return(instance_double(Twilio::VoiceWebhookSetupService, perform: twiml_app_sid))
  end

  it 'has a valid factory' do
    expect(channel).to be_valid
  end

  describe 'validations' do
    it 'validates presence of provider_config' do
      channel.provider_config = nil
      expect(channel).not_to be_valid
      expect(channel.errors[:provider_config]).to be_present
    end

    it 'validates presence of account_sid in provider_config' do
      channel.provider_config = { auth_token: 'token' }
      expect(channel).not_to be_valid
      expect(channel.errors[:provider_config]).to include('account_sid is required for Twilio provider')
    end

    it 'validates presence of auth_token in provider_config' do
      channel.provider_config = { account_sid: 'sid' }
      expect(channel).not_to be_valid
      expect(channel.errors[:provider_config]).to include('auth_token is required for Twilio provider')
    end

    it 'validates presence of api_key_sid in provider_config' do
      channel.provider_config = { account_sid: 'sid', auth_token: 'token' }
      expect(channel).not_to be_valid
      expect(channel.errors[:provider_config]).to include('api_key_sid is required for Twilio provider')
    end

    it 'validates presence of api_key_secret in provider_config' do
      channel.provider_config = { account_sid: 'sid', auth_token: 'token', api_key_sid: 'key' }
      expect(channel).not_to be_valid
      expect(channel.errors[:provider_config]).to include('api_key_secret is required for Twilio provider')
    end

    it 'validates presence of twiml_app_sid in provider_config' do
      channel.provider_config = { account_sid: 'sid', auth_token: 'token', api_key_sid: 'key', api_key_secret: 'secret' }
      expect(channel).not_to be_valid
      expect(channel.errors[:provider_config]).to include('twiml_app_sid is required for Twilio provider')
    end

    it 'is valid with all required provider_config fields' do
      channel.provider_config = {
        account_sid: 'test_sid',
        auth_token: 'test_token',
        api_key_sid: 'test_key',
        api_key_secret: 'test_secret',
        twiml_app_sid: 'test_app_sid'
      }
      expect(channel).to be_valid
    end

    it 'is valid with Sipuni account number and generated webhook token' do
      sipuni_channel = create(
        :channel_voice,
        provider: 'sipuni',
        provider_config: { account_number: '123456', audio_mode: 'external_softphone' }
      )

      expect(sipuni_channel.provider_config.with_indifferent_access[:webhook_token]).to be_present
    end

    it 'preserves the Sipuni webhook token when config is updated without a token' do
      sipuni_channel = create(:channel_voice, :sipuni)
      token = sipuni_channel.provider_config.with_indifferent_access[:webhook_token]

      sipuni_channel.update!(
        provider_config: {
          account_number: 'updated-account',
          default_internal_number: '101',
          audio_mode: 'external_softphone'
        }
      )

      expect(sipuni_channel.reload.provider_config.with_indifferent_access[:webhook_token]).to eq(token)
    end

    it 'validates presence of Sipuni account number' do
      sipuni_channel = build(:channel_voice, account: create(:account), provider: 'sipuni', provider_config: { webhook_token: 'token' })

      expect(sipuni_channel).not_to be_valid
      expect(sipuni_channel.errors[:provider_config]).to include('account_number is required for Sipuni provider')
    end
  end

  describe '#name' do
    it 'returns Voice with phone number' do
      expect(channel.name).to include('Voice')
      expect(channel.name).to include(channel.phone_number)
    end
  end

  describe 'provisioning on create' do
    it 'stores twiml_app_sid in provider_config' do
      ch = create(:channel_voice)
      expect(ch.provider_config.with_indifferent_access[:twiml_app_sid]).to eq(twiml_app_sid)
    end
  end

  describe '#sipuni_events_webhook_url' do
    it 'builds the Sipuni webhook URL with the inbox id and generated token' do
      sipuni_channel = create(:channel_voice, :sipuni)
      token = sipuni_channel.provider_config.with_indifferent_access[:webhook_token]

      expect(sipuni_channel.sipuni_events_webhook_url).to include("/webhooks/sipuni/voice/#{sipuni_channel.inbox.id}")
      expect(sipuni_channel.sipuni_events_webhook_url).to include("token=#{token}")
    end
  end
end
