require 'rails_helper'

describe Whatsapp::EmbeddedSignupService do
  let(:account) { create(:account) }
  let(:params) do
    {
      code: 'test_authorization_code',
      business_id: 'test_business_id',
      waba_id: 'test_waba_id',
      phone_number_id: 'test_phone_number_id'
    }
  end
  let(:service) { described_class.new(account: account, params: params) }
  let(:access_token) { 'test_access_token' }
  let(:token_health) do
    {
      'status' => 'healthy',
      'waba_access' => true,
      'phone_number_access' => true
    }
  end
  let(:phone_info) do
    {
      phone_number_id: params[:phone_number_id],
      phone_number: '+1234567890',
      verified: true,
      business_name: 'Test Business'
    }
  end
  let(:channel) { instance_double(Channel::Whatsapp) }

  describe '#perform' do
    before do
      allow(GlobalConfig).to receive(:clear_cache)

      # Mock service dependencies
      token_exchange = instance_double(Whatsapp::TokenExchangeService)
      allow(Whatsapp::TokenExchangeService).to receive(:new).with(params[:code]).and_return(token_exchange)
      allow(token_exchange).to receive(:perform).and_return(access_token)

      phone_service = instance_double(Whatsapp::PhoneInfoService)
      allow(Whatsapp::PhoneInfoService).to receive(:new)
        .with(params[:waba_id], params[:phone_number_id], access_token).and_return(phone_service)
      allow(phone_service).to receive(:perform).and_return(phone_info)

      validation_service = instance_double(Whatsapp::TokenValidationService)
      allow(Whatsapp::TokenValidationService).to receive(:new)
        .with(access_token, params[:waba_id], phone_number_id: params[:phone_number_id]).and_return(validation_service)
      allow(validation_service).to receive(:perform).and_return(token_health)

      channel_creation = instance_double(Whatsapp::ChannelCreationService)
      allow(Whatsapp::ChannelCreationService).to receive(:new)
        .with(account, { waba_id: params[:waba_id], business_id: params[:business_id], business_name: 'Test Business' }, phone_info, access_token)
        .and_return(channel_creation)
      allow(channel_creation).to receive(:perform).and_return(channel)

      allow(channel).to receive(:setup_webhooks)
      allow(channel).to receive(:store_token_health!)
      allow(channel).to receive(:phone_number).and_return('+1234567890')
      allow(channel).to receive(:reauthorized!)

      health_service = instance_double(Whatsapp::HealthService)
      allow(Whatsapp::HealthService).to receive(:new).and_return(health_service)
      allow(health_service).to receive(:fetch_health_status).and_return({
                                                                          platform_type: 'CLOUD_API',
                                                                          throughput: { 'level' => 'STANDARD' },
                                                                          messaging_limit_tier: 'TIER_1000'
                                                                        })
    end

    it 'creates channel and sets up webhooks' do
      expect(channel).to receive(:setup_webhooks).with(strict: true)

      result = service.perform
      expect(result).to eq(channel)
    end

    it 'stores token health metadata on the channel' do
      expect(channel).to receive(:store_token_health!).with(token_health)

      service.perform
    end

    it 'sets up webhooks after the initial channel is committed' do
      baseline_open_transactions = ActiveRecord::Base.connection.open_transactions

      allow(Whatsapp::ChannelCreationService).to receive(:new).and_call_original
      allow_any_instance_of(Channel::Whatsapp).to receive(:validate_provider_config).and_return(true)
      allow_any_instance_of(Channel::Whatsapp).to receive(:sync_templates).and_return(true)

      webhook_service = instance_double(Whatsapp::WebhookSetupService)
      allow(webhook_service).to receive(:perform).and_return(true)
      allow(Whatsapp::WebhookSetupService).to receive(:new) do |created_channel, _waba_id, _access_token, _options|
        expect(created_channel).to be_persisted
        expect(ActiveRecord::Base.connection.open_transactions).to eq(baseline_open_transactions)
        webhook_service
      end

      service.perform
    end

    it 'checks health status after channel creation' do
      health_service = instance_double(Whatsapp::HealthService)
      allow(Whatsapp::HealthService).to receive(:new).and_return(health_service)
      expect(health_service).to receive(:fetch_health_status)

      service.perform
    end

    context 'when channel is in pending state' do
      it 'prompts reauthorization for pending channel' do
        health_service = instance_double(Whatsapp::HealthService)
        allow(Whatsapp::HealthService).to receive(:new).and_return(health_service)
        allow(health_service).to receive(:fetch_health_status).and_return({
                                                                            platform_type: 'NOT_APPLICABLE',
                                                                            throughput: { 'level' => 'STANDARD' },
                                                                            messaging_limit_tier: 'TIER_1000'
                                                                          })

        expect(channel).to receive(:prompt_reauthorization!)
        service.perform
      end

      it 'prompts reauthorization when throughput level is NOT_APPLICABLE' do
        health_service = instance_double(Whatsapp::HealthService)
        allow(Whatsapp::HealthService).to receive(:new).and_return(health_service)
        allow(health_service).to receive(:fetch_health_status).and_return({
                                                                            platform_type: 'CLOUD_API',
                                                                            throughput: { 'level' => 'NOT_APPLICABLE' },
                                                                            messaging_limit_tier: 'TIER_1000'
                                                                          })

        expect(channel).to receive(:prompt_reauthorization!)
        service.perform
      end
    end

    context 'when channel is healthy' do
      it 'does not prompt reauthorization for healthy channel' do
        expect(channel).not_to receive(:prompt_reauthorization!)
        service.perform
      end
    end

    context 'when parameters are invalid' do
      it 'raises ArgumentError for missing parameters' do
        invalid_service = described_class.new(account: account, params: { code: '', business_id: '', waba_id: '' })
        expect { invalid_service.perform }.to raise_error(ArgumentError, /Required parameters are missing/)
      end
    end

    context 'when service fails' do
      it 'logs and re-raises errors' do
        token_exchange = instance_double(Whatsapp::TokenExchangeService)
        allow(Whatsapp::TokenExchangeService).to receive(:new).and_return(token_exchange)
        allow(token_exchange).to receive(:perform).and_raise('Token error')

        expect(Rails.logger).to receive(:error).with('[WHATSAPP] Embedded signup failed: Token error')
        expect { service.perform }.to raise_error('Token error')
      end

      it 'rolls back the new inbox/channel and fails when strict webhook setup fails' do
        allow(Whatsapp::ChannelCreationService).to receive(:new).and_call_original
        allow_any_instance_of(Channel::Whatsapp).to receive(:validate_provider_config).and_return(true)
        allow_any_instance_of(Channel::Whatsapp).to receive(:sync_templates).and_return(true)
        allow_any_instance_of(Channel::Whatsapp).to receive(:teardown_webhooks).and_return(true)
        webhook_service = instance_double(Whatsapp::WebhookSetupService)
        allow(Whatsapp::WebhookSetupService).to receive(:new).and_return(webhook_service)
        allow(webhook_service).to receive(:perform).and_raise('Webhook setup error')

        expect do
          service.perform
        end.to raise_error('Webhook setup error')
          .and not_change(Channel::Whatsapp, :count)
          .and not_change(Inbox, :count)
      end
    end

    context 'with reauthorization flow' do
      let(:inbox_id) { 123 }
      let(:reauth_service) { instance_double(Whatsapp::ReauthorizationService) }
      let(:service_with_inbox) do
        described_class.new(account: account, params: params, inbox_id: inbox_id)
      end

      before do
        allow(Whatsapp::ReauthorizationService).to receive(:new).with(
          account: account,
          inbox_id: inbox_id,
          phone_number_id: params[:phone_number_id],
          business_id: params[:business_id],
          waba_id: params[:waba_id]
        ).and_return(reauth_service)
        allow(reauth_service).to receive(:perform).with(access_token, phone_info).and_return(channel)

        allow(channel).to receive(:phone_number).and_return('+1234567890')
        allow(channel).to receive(:reauthorized!)

        health_service = instance_double(Whatsapp::HealthService)
        allow(Whatsapp::HealthService).to receive(:new).and_return(health_service)
        allow(health_service).to receive(:fetch_health_status).and_return({
                                                                            platform_type: 'CLOUD_API',
                                                                            throughput: { 'level' => 'STANDARD' },
                                                                            messaging_limit_tier: 'TIER_1000'
                                                                          })
      end

      it 'uses ReauthorizationService and sets up webhooks' do
        expect(reauth_service).to receive(:perform)
        expect(channel).to receive(:setup_webhooks).with(strict: true)
        expect(channel).to receive(:reauthorized!)

        result = service_with_inbox.perform
        expect(result).to eq(channel)
      end

      context 'with real channel requiring reauthorization' do
        let(:inbox) { create(:inbox, account: account) }
        let(:whatsapp_channel) do
          create(:channel_whatsapp, account: account, phone_number: '+1234567890',
                                    validate_provider_config: false, sync_templates: false)
        end
        let(:service_with_real_inbox) { described_class.new(account: account, params: params, inbox_id: inbox.id) }
        let(:phone_info) do
          {
            phone_number_id: params[:phone_number_id],
            phone_number: whatsapp_channel.phone_number,
            verified: true,
            business_name: 'Test Business'
          }
        end

        before do
          inbox.update!(channel: whatsapp_channel)
          whatsapp_channel.prompt_reauthorization!

          setup_reauthorization_mocks
          setup_health_service_mock
        end

        it 'clears reauthorization flag when reauthorization completes' do
          expect(whatsapp_channel.reauthorization_required?).to be true

          result = service_with_real_inbox.perform

          expect(result).to eq(whatsapp_channel)
          expect(whatsapp_channel.reauthorization_required?).to be false
        end

        it 'rolls back reauthorization config when strict webhook setup fails' do
          original_provider_config = whatsapp_channel.reload.provider_config.deep_dup
          allow(Whatsapp::ReauthorizationService).to receive(:new).and_call_original
          allow_any_instance_of(Channel::Whatsapp).to receive(:validate_provider_config).and_return(true)
          webhook_service = instance_double(Whatsapp::WebhookSetupService)
          allow(Whatsapp::WebhookSetupService).to receive(:new).and_return(webhook_service)
          allow(webhook_service).to receive(:perform).and_raise('Webhook setup error')

          expect { service_with_real_inbox.perform }.to raise_error('Webhook setup error')

          expect(whatsapp_channel.reload.provider_config).to eq(original_provider_config)
          expect(whatsapp_channel.reauthorization_required?).to be(true)
        end

        private

        def setup_reauthorization_mocks
          reauth_service = stub_reauthorization_service

          allow(reauth_service).to receive(:perform) do
            whatsapp_channel
          end

          allow(whatsapp_channel).to receive(:setup_webhooks).and_return(true)
        end

        def stub_reauthorization_service
          reauth_service = instance_double(Whatsapp::ReauthorizationService)
          allow(Whatsapp::ReauthorizationService).to receive(:new).with(
            account: account,
            inbox_id: inbox.id,
            phone_number_id: params[:phone_number_id],
            business_id: params[:business_id],
            waba_id: params[:waba_id]
          ).and_return(reauth_service)
          reauth_service
        end

        def setup_health_service_mock
          health_service = instance_double(Whatsapp::HealthService)
          allow(Whatsapp::HealthService).to receive(:new).and_return(health_service)
          allow(health_service).to receive(:fetch_health_status).and_return({
                                                                              platform_type: 'CLOUD_API',
                                                                              throughput: { 'level' => 'STANDARD' },
                                                                              messaging_limit_tier: 'TIER_1000'
                                                                            })
        end
      end
    end
  end
end
