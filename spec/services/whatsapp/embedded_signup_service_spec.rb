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
  let(:require_non_expiring_system_user_token) { false }
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

      allow(GlobalConfigService).to receive(:load).and_call_original
      allow(GlobalConfigService).to receive(:load)
        .with('WHATSAPP_REQUIRE_NON_EXPIRING_SYSTEM_USER_TOKEN', false)
        .and_return(require_non_expiring_system_user_token)

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
        .with(
          access_token,
          params[:waba_id],
          phone_number_id: params[:phone_number_id],
          require_non_expiring_system_user: require_non_expiring_system_user_token
        ).and_return(validation_service)
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
      expect(channel).to receive(:setup_webhooks).with(strict: true, force_registration: true)

      result = service.perform
      expect(result).to eq(channel)
    end

    context 'when non-expiring token enforcement is enabled' do
      let(:require_non_expiring_system_user_token) { true }

      it 'requires the native non-expiring system-user token contract' do
        expect(service.perform).to eq(channel)
      end

      it 'rejects an expiring token before channel persistence' do
        inspection_service = instance_double(
          Whatsapp::TokenInspectionService,
          perform: {
            'status' => 'expiring',
            'token_type' => 'SYSTEM_USER',
            'never_expires' => false
          }
        )
        allow(Whatsapp::TokenInspectionService).to receive(:new).and_return(inspection_service)
        allow(Whatsapp::TokenValidationService).to receive(:new).and_call_original

        expect(Whatsapp::ChannelCreationService).not_to receive(:new)

        expect { service.perform }.to raise_error(RuntimeError, /non-expiring SYSTEM_USER token/)
      end
    end

    it 'persists token health metadata on the channel' do
      expect(channel).to receive(:store_token_health!).with(token_health)

      service.perform
    end

    it 'sets up webhooks after the initial channel is committed' do
      baseline_open_transactions = ActiveRecord::Base.connection.open_transactions

      allow(Whatsapp::ChannelCreationService).to receive(:new).and_call_original
      stub_new_channel_callbacks

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
        stub_new_channel_callbacks(teardown: true)
        webhook_service = instance_double(Whatsapp::WebhookSetupService)
        allow(Whatsapp::WebhookSetupService).to receive(:new).and_return(webhook_service)
        allow(webhook_service).to receive(:perform).and_raise('Webhook setup error')

        expect do
          service.perform
        end.to raise_error('Webhook setup error')
          .and not_change(Channel::Whatsapp, :count)
          .and not_change(Inbox, :count)
      end

      it 'does not mutate the remote subscription again when callback setup failed cleanly' do
        allow(Whatsapp::ChannelCreationService).to receive(:new).and_call_original
        stub_new_channel_callbacks
        webhook_service = instance_double(Whatsapp::WebhookSetupService)
        allow(Whatsapp::WebhookSetupService).to receive(:new).and_return(webhook_service)
        error = Whatsapp::WebhookSetupService::CallbackSetupError.new('Webhook setup failed cleanly')
        allow(webhook_service).to receive(:perform).and_raise(error)
        expect(Whatsapp::WebhookTeardownService).not_to receive(:new)

        expect do
          service.perform
        end.to raise_error(error)
          .and not_change(Channel::Whatsapp, :count)
          .and not_change(Inbox, :count)
      end

      it 'preserves the new channel as a recovery anchor when remote compensation fails' do
        allow(Whatsapp::ChannelCreationService).to receive(:new).and_call_original
        stub_new_channel_callbacks(teardown: true)
        webhook_service = instance_double(Whatsapp::WebhookSetupService)
        allow(Whatsapp::WebhookSetupService).to receive(:new).and_return(webhook_service)
        error = Whatsapp::FacebookApiClient::WebhookSubscriptionCompensationError.new('Compensation failed')
        allow(webhook_service).to receive(:perform).and_raise(error)

        expect do
          service.perform
        end.to raise_error(error)
          .and change(Channel::Whatsapp, :count).by(1)
          .and change(Inbox, :count).by(1)

        expect(Channel::Whatsapp.order(:id).last.reauthorization_required?).to be(true)
      end

      it 'preserves the new channel as a recovery anchor when callback outcome is unknown' do
        allow(Whatsapp::ChannelCreationService).to receive(:new).and_call_original
        stub_new_channel_callbacks(teardown: true)
        webhook_service = instance_double(Whatsapp::WebhookSetupService)
        allow(Whatsapp::WebhookSetupService).to receive(:new).and_return(webhook_service)
        error = Whatsapp::FacebookApiClient::WebhookCallbackOutcomeUnknownError.new('Callback outcome unknown')
        allow(webhook_service).to receive(:perform).and_raise(error)

        expect do
          service.perform
        end.to raise_error(error)
          .and change(Channel::Whatsapp, :count).by(1)
          .and change(Inbox, :count).by(1)

        expect(Channel::Whatsapp.order(:id).last.reauthorization_required?).to be(true)
      end

      it 'preserves the new channel when the remote callback changed before local recovery finalization failed' do
        allow(Whatsapp::ChannelCreationService).to receive(:new).and_call_original
        stub_new_channel_callbacks(teardown: true)
        webhook_service = instance_double(Whatsapp::WebhookSetupService)
        allow(Whatsapp::WebhookSetupService).to receive(:new).and_return(webhook_service)
        error = Whatsapp::WebhookSetupService::PostMutationRecoveryError.new('Recovery persistence failed')
        allow(webhook_service).to receive(:perform).and_raise(error)

        expect do
          service.perform
        end.to raise_error(error)
          .and change(Channel::Whatsapp, :count).by(1)
          .and change(Inbox, :count).by(1)

        expect(Channel::Whatsapp.order(:id).last.reauthorization_required?).to be(true)
      end
    end

    context 'with reauthorization flow' do
      let(:params) { super().merge(signup_type: 'standard') }
      let(:existing_channel) do
        create(:channel_whatsapp, account: account, provider: 'whatsapp_cloud',
                                  validate_provider_config: false, sync_templates: false)
      end
      let(:existing_inbox) { existing_channel.inbox || create(:inbox, account: account, channel: existing_channel) }
      let(:inbox_id) { existing_inbox.id }
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
          waba_id: params[:waba_id],
          signup_type: 'standard'
        ).and_return(reauth_service)
        allow(reauth_service).to receive(:perform).with(access_token, phone_info).and_yield(channel).and_return(channel)

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
        existing_channel.update!(provider_config: existing_channel.provider_config.merge(
          'embedded_signup_flow' => 'standard',
          'phone_number_id' => params[:phone_number_id],
          'business_account_id' => params[:waba_id],
          'business_id' => params[:business_id]
        ))
        expect(reauth_service).to receive(:perform).and_yield(channel).and_return(channel)
        expect(channel).to receive(:setup_webhooks).with(strict: true, force_registration: false)
        expect(channel).to receive(:reauthorized!)

        result = service_with_inbox.perform
        expect(result).to eq(channel)
      end

      context 'when the requested flow conflicts with the persisted channel flow' do
        let(:existing_channel) do
          create(
            :channel_whatsapp,
            account: account,
            provider: 'whatsapp_cloud',
            provider_config: { 'embedded_signup_flow' => 'coexistence' },
            validate_provider_config: false,
            sync_templates: false
          )
        end

        it 'rejects the mode transition before exchanging the authorization code' do
          expect(Whatsapp::TokenExchangeService).not_to receive(:new)

          expect { service_with_inbox.perform }
            .to raise_error(Whatsapp::EmbeddedSignupService::ReauthorizationFlowMismatchError)
        end
      end

      context 'when the completion event conflicts with the persisted provider identity' do
        let(:existing_channel) do
          create(
            :channel_whatsapp,
            account: account,
            provider: 'whatsapp_cloud',
            provider_config: {
              'embedded_signup_flow' => 'standard',
              'phone_number_id' => 'persisted-phone',
              'business_account_id' => 'persisted-waba',
              'business_id' => 'persisted-business'
            },
            validate_provider_config: false,
            sync_templates: false
          )
        end

        it 'rejects the identity transition before exchanging the authorization code' do
          expect(Whatsapp::TokenExchangeService).not_to receive(:new)

          expect { service_with_inbox.perform }
            .to raise_error(Whatsapp::ReauthorizationService::IdentityMismatchError)
        end
      end

      context 'when a legacy channel has no persisted flow and the user made no selection' do
        let(:params) { super().except(:signup_type) }

        it 'fails closed before exchanging the authorization code' do
          expect(Whatsapp::TokenExchangeService).not_to receive(:new)

          expect { service_with_inbox.perform }
            .to raise_error(Whatsapp::EmbeddedSignupService::ReauthorizationFlowRequiredError)
        end
      end

      context 'when a known standard channel receives the official WABA-only event' do
        let(:params) { { code: 'test_authorization_code', waba_id: 'server_waba_id' } }
        let(:phone_info) do
          {
            phone_number_id: 'server_phone_id',
            phone_number: '+123****7890',
            verified: true,
            business_name: 'Test Business'
          }
        end
        let(:existing_channel) do
          create(
            :channel_whatsapp,
            account: account,
            provider: 'whatsapp_cloud',
            validate_provider_config: false,
            sync_templates: false
          ).tap do |record|
            record.update!(provider_config: record.provider_config.merge(
              'embedded_signup_flow' => 'standard',
              'phone_number_id' => 'server_phone_id',
              'business_account_id' => 'server_waba_id',
              'business_id' => 'server_business_id'
            ))
          end
        end

        before do
          phone_service = instance_double(Whatsapp::PhoneInfoService, perform: phone_info)
          allow(Whatsapp::PhoneInfoService).to receive(:new)
            .with('server_waba_id', 'server_phone_id', access_token)
            .and_return(phone_service)

          validation_service = instance_double(Whatsapp::TokenValidationService, perform: token_health)
          allow(Whatsapp::TokenValidationService).to receive(:new)
            .with(
              access_token,
              'server_waba_id',
              phone_number_id: 'server_phone_id',
              require_non_expiring_system_user: false
            ).and_return(validation_service)

          allow(Whatsapp::ReauthorizationService).to receive(:new).with(
            account: account,
            inbox_id: inbox_id,
            phone_number_id: 'server_phone_id',
            business_id: 'server_business_id',
            waba_id: 'server_waba_id',
            signup_type: 'standard'
          ).and_return(reauth_service)
        end

        it 'uses server-owned phone and business identifiers' do
          expect(service_with_inbox.perform).to eq(channel)
        end
      end

      context 'with real channel requiring reauthorization' do
        let(:whatsapp_channel) do
          create(:channel_whatsapp, account: account, phone_number: '+123****7890',
                                    provider: 'whatsapp_cloud', validate_provider_config: false, sync_templates: false)
        end

        def inbox
          @inbox ||= create(:inbox, account: account)
        end

        def service_with_real_inbox
          described_class.new(account: account, params: params, inbox_id: inbox.id)
        end

        def phone_info
          {
            phone_number_id: params[:phone_number_id],
            phone_number: whatsapp_channel.phone_number,
            verified: true,
            business_name: 'Test Business'
          }
        end

        before do
          inbox.update!(channel: whatsapp_channel)
          whatsapp_channel.update!(provider_config: whatsapp_channel.provider_config.merge(
            'embedded_signup_flow' => 'standard',
            'phone_number_id' => params[:phone_number_id],
            'business_account_id' => params[:waba_id],
            'business_id' => params[:business_id]
          ))
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

        it 'keeps committed reauthorization config when strict webhook setup fails' do
          original_provider_config = whatsapp_channel.reload.provider_config.deep_dup
          allow(Whatsapp::ReauthorizationService).to receive(:new).and_call_original
          provider_service = instance_double(Whatsapp::Providers::WhatsappCloudService, validate_provider_config?: true)
          allow(Whatsapp::Providers::WhatsappCloudService).to receive(:new).and_return(provider_service)
          webhook_service = instance_double(Whatsapp::WebhookSetupService)
          allow(Whatsapp::WebhookSetupService).to receive(:new).and_return(webhook_service)
          allow(webhook_service).to receive(:perform).and_raise('Webhook setup error')

          expect { service_with_real_inbox.perform }.to raise_error('Webhook setup error')

          persisted_config = whatsapp_channel.reload.provider_config
          expect(persisted_config).not_to eq(original_provider_config)
          expect(persisted_config).to include(
            'api_key' => 'test_access_token',
            'business_account_id' => 'test_waba_id',
            'phone_number_id' => 'test_phone_number_id'
          )
          expect(whatsapp_channel.reauthorization_required?).to be(true)
        end

        private

        def setup_reauthorization_mocks
          reauth_service = stub_reauthorization_service

          allow(reauth_service).to receive(:perform) do |*, &block|
            block.call(whatsapp_channel)
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
            waba_id: params[:waba_id],
            signup_type: 'standard'
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

    context 'with WhatsApp Business app coexistence onboarding' do
      let(:params) do
        {
          code: 'coexistence_code',
          waba_id: 'coexistence_waba',
          signup_type: 'coexistence'
        }
      end
      let(:phone_info) do
        {
          phone_number_id: 'coexistence_phone_id',
          phone_number: '+77010002030',
          verified: true,
          business_name: 'Business App',
          is_on_biz_app: true,
          platform_type: 'CLOUD_API'
        }
      end

      before do
        phone_service = instance_double(Whatsapp::PhoneInfoService, perform: phone_info)
        allow(Whatsapp::PhoneInfoService).to receive(:new)
          .with(params[:waba_id], nil, access_token, coexistence: true)
          .and_return(phone_service)

        validation_service = instance_double(Whatsapp::TokenValidationService, perform: token_health)
        allow(Whatsapp::TokenValidationService).to receive(:new)
          .with(
            access_token,
            params[:waba_id],
            phone_number_id: phone_info[:phone_number_id],
            require_non_expiring_system_user: false
          )
          .and_return(validation_service)

        channel_creation = instance_double(Whatsapp::ChannelCreationService, perform: channel)
        allow(Whatsapp::ChannelCreationService).to receive(:new)
          .with(
            account,
            { waba_id: params[:waba_id], business_id: nil, business_name: phone_info[:business_name] },
            phone_info,
            access_token,
            signup_type: 'coexistence'
          ).and_return(channel_creation)
        allow(channel).to receive(:id).and_return(42)
        allow(channel).to receive(:provider_config).and_return(
          'coexistence_sync' => { 'generation' => 'generation-1' }
        )
      end

      it 'resolves the selected business-app phone and schedules the mandatory sync' do
        expect { service.perform }.to have_enqueued_job(Whatsapp::CoexistenceSyncJob).with(42, 'generation-1')
        expect(channel).to have_received(:setup_webhooks).with(strict: true, force_registration: false)
      end

      it 'rejects a phone that Meta does not mark as coexistence' do
        phone_info[:is_on_biz_app] = false

        expect { service.perform }.to raise_error(/not connected to both WhatsApp Business app and Cloud API/)
      end
    end

    def stub_new_channel_callbacks(teardown: false)
      allow(Channel::Whatsapp).to receive(:build).and_wrap_original do |original, *args|
        original.call(*args).tap do |built_channel|
          allow(built_channel).to receive(:validate_provider_config).and_return(true)
          allow(built_channel).to receive(:sync_templates).and_return(true)
          allow(built_channel).to receive(:teardown_webhooks).and_return(true) if teardown
        end
      end
    end
  end
end
