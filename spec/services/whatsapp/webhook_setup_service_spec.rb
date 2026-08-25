require 'rails_helper'

describe Whatsapp::WebhookSetupService do
  let(:channel) do
    create(:channel_whatsapp,
           phone_number: '+1234567890',
           provider_config: {
             'phone_number_id' => '123456789',
             'business_account_id' => 'test_waba_id',
             'api_key' => 'test_access_token',
             'webhook_verify_token' => 'test_verify_token',
             'source' => 'embedded_signup'
           },
           provider: 'whatsapp_cloud',
           sync_templates: false,
           validate_provider_config: false)
  end
  let(:waba_id) { '123456789' }
  let(:access_token) { 'test_key' }
  let(:service) { described_class.new(channel, waba_id, access_token) }
  let(:api_client) { instance_double(Whatsapp::FacebookApiClient) }
  let(:health_service) { instance_double(Whatsapp::HealthService) }

  before do
    # Stub webhook teardown to prevent HTTP calls during cleanup
    stub_request(:delete, /graph.facebook.com/).to_return(status: 200, body: '{}', headers: {})

    # Clean up any existing channels to avoid phone number conflicts
    Channel::Whatsapp.destroy_all
    allow(Whatsapp::FacebookApiClient).to receive(:new).and_return(api_client)
    allow(Whatsapp::HealthService).to receive(:new).and_return(health_service)
    allow(GlobalConfigService).to receive(:load).and_call_original
    allow(GlobalConfigService).to receive(:load).with('WHATSAPP_WEBHOOK_VERIFY_TOKEN', nil).and_return('test_verify_token')

    # Default stubs for phone_number_verified? and health service
    allow(api_client).to receive(:phone_number_verified?).and_return(false)
    allow(health_service).to receive(:fetch_health_status).and_return({
                                                                        platform_type: 'APPLICABLE',
                                                                        throughput: { level: 'APPLICABLE' }
                                                                      })
  end

  describe '#register_callback' do
    it 'keeps the WABA lock held through the provider subscription call' do
      lock = instance_double(Whatsapp::WabaLock)
      lock_held = false
      allow(Whatsapp::WabaLock).to receive(:new).with(waba_id).and_return(lock)
      allow(lock).to receive(:with_lock) do |&block|
        lock_held = true
        block.call
      ensure
        lock_held = false
      end
      expect(api_client).to receive(:subscribe_waba_webhook) do
        expect(lock_held).to be(true)
      end

      with_modified_env FRONTEND_URL: 'https://one-link.kz' do
        service.register_callback
      end

      expect(channel.reload.provider_config[described_class::CALLBACK_RECOVERY_KEY]).to include(
        'state' => 'resolved',
        'waba_id' => waba_id,
        'callback_url' => 'https://one-link.kz/webhooks/whatsapp',
        'attempt_count' => 1,
        'subscribed_fields' => Whatsapp::FacebookApiClient::WEBHOOK_DEFAULT_FIELDS
      )
    end

    it 'uses the referenced channel callback and channel verify token for manual setup' do
      channel.provider_config = channel.provider_config.merge(
        'source' => nil,
        'webhook_verify_token' => 'manual-channel-token'
      )
      allow(GlobalConfigService).to receive(:load)
        .with(described_class::PUBLIC_INGRESS_CONFIG_KEY, nil).and_return('https://app.one-link.kz/webhooks/whatsapp')

      with_modified_env FRONTEND_URL: 'https://one-link.kz', WHATSAPP_WEBHOOK_VERIFY_TOKEN: nil do
        expect(api_client).to receive(:subscribe_waba_webhook).with(
          waba_id,
          "https://one-link.kz/webhooks/whatsapp?channel_id=#{channel.id}",
          'manual-channel-token'
        )

        service.register_callback
      end
    end

    it 'uses the shared production ingress for embedded callbacks in another runtime' do
      allow(GlobalConfigService).to receive(:load)
        .with(described_class::PUBLIC_INGRESS_CONFIG_KEY, nil).and_return('https://app.one-link.kz/webhooks/whatsapp')
      allow(GlobalConfigService).to receive(:load)
        .with(described_class::PUBLIC_INGRESS_VERIFY_TOKEN_CONFIG_KEY, nil).and_return('production-verify-token')
      expect(api_client).to receive(:subscribe_waba_webhook).with(
        waba_id,
        'https://app.one-link.kz/webhooks/whatsapp',
        'production-verify-token'
      )

      with_modified_env FRONTEND_URL: 'https://dev.one-link.kz' do
        service.register_callback
      end
    end

    it 'registers the exact remote route before changing the shared provider callback' do
      route_client = instance_double(Whatsapp::WebhookRouteRegistryClient, configured?: true)
      registration_token = SecureRandom.uuid
      allow(Whatsapp::WebhookRouteRegistryClient).to receive(:new).and_return(route_client)
      allow(GlobalConfigService).to receive(:load)
        .with(described_class::PUBLIC_INGRESS_CONFIG_KEY, nil).and_return('https://app.one-link.kz/webhooks/whatsapp')
      allow(GlobalConfigService).to receive(:load)
        .with(described_class::PUBLIC_INGRESS_VERIFY_TOKEN_CONFIG_KEY, nil).and_return('production-verify-token')

      expect(route_client).to receive(:register!)
        .with(waba_id: waba_id, phone_number_id: '123456789').ordered.and_return(
          Whatsapp::WebhookRouteRegistryClient::Registration.new(status: :created, token: registration_token)
        )
      expect(api_client).to receive(:subscribe_waba_webhook).ordered

      service.register_callback

      expect(channel.reload.provider_config[Whatsapp::WebhookRouteRegistryClient::REGISTRATION_TOKEN_CONFIG_KEY])
        .to eq(registration_token)
    end

    it 'removes a newly created remote route when callback setup fails before provider mutation' do
      route_client = instance_double(Whatsapp::WebhookRouteRegistryClient, configured?: true)
      recovery_service = instance_double(Whatsapp::WebhookCallbackRecoveryService)
      allow(Whatsapp::WebhookRouteRegistryClient).to receive(:new).and_return(route_client)
      allow(Whatsapp::WebhookCallbackRecoveryService).to receive(:new).and_return(recovery_service)
      allow(GlobalConfigService).to receive(:load)
        .with(described_class::PUBLIC_INGRESS_CONFIG_KEY, nil).and_return('https://app.one-link.kz/webhooks/whatsapp')
      allow(GlobalConfigService).to receive(:load)
        .with(described_class::PUBLIC_INGRESS_VERIFY_TOKEN_CONFIG_KEY, nil).and_return('production-verify-token')
      registration_token = SecureRandom.uuid
      allow(route_client).to receive(:register!).and_return(
        Whatsapp::WebhookRouteRegistryClient::Registration.new(status: :created, token: registration_token)
      )
      allow(recovery_service).to receive(:updating!).and_raise(ActiveRecord::ConnectionNotEstablished)
      allow(recovery_service).to receive(:failed!)

      expect(route_client).to receive(:unregister!).with(
        waba_id: waba_id,
        phone_number_id: '123456789',
        registration_token: registration_token
      )
      expect(api_client).not_to receive(:subscribe_waba_webhook)

      expect { service.register_callback }.to raise_error(described_class::CallbackSetupError)
    end

    it 'preserves an existing remote route when callback setup fails before provider mutation' do
      route_client = instance_double(Whatsapp::WebhookRouteRegistryClient, configured?: true)
      recovery_service = instance_double(Whatsapp::WebhookCallbackRecoveryService)
      allow(Whatsapp::WebhookRouteRegistryClient).to receive(:new).and_return(route_client)
      allow(Whatsapp::WebhookCallbackRecoveryService).to receive(:new).and_return(recovery_service)
      allow(GlobalConfigService).to receive(:load)
        .with(described_class::PUBLIC_INGRESS_CONFIG_KEY, nil).and_return('https://app.one-link.kz/webhooks/whatsapp')
      allow(GlobalConfigService).to receive(:load)
        .with(described_class::PUBLIC_INGRESS_VERIFY_TOKEN_CONFIG_KEY, nil).and_return('production-verify-token')
      registration_token = SecureRandom.uuid
      allow(route_client).to receive(:register!).and_return(
        Whatsapp::WebhookRouteRegistryClient::Registration.new(status: :existing, token: registration_token)
      )
      allow(recovery_service).to receive(:updating!).and_raise(ActiveRecord::ConnectionNotEstablished)
      allow(recovery_service).to receive(:failed!)

      expect(route_client).not_to receive(:unregister!)

      expect { service.register_callback }.to raise_error(described_class::CallbackSetupError)
    end

    it 'does not change the provider callback when route registration fails' do
      route_client = instance_double(Whatsapp::WebhookRouteRegistryClient, configured?: true)
      allow(Whatsapp::WebhookRouteRegistryClient).to receive(:new).and_return(route_client)
      allow(route_client).to receive(:register!).and_raise(Whatsapp::WebhookRouteRegistryClient::Error, 'registry unavailable')
      allow(GlobalConfigService).to receive(:load)
        .with(described_class::PUBLIC_INGRESS_CONFIG_KEY, nil).and_return('https://app.one-link.kz/webhooks/whatsapp')
      allow(GlobalConfigService).to receive(:load)
        .with(described_class::PUBLIC_INGRESS_VERIFY_TOKEN_CONFIG_KEY, nil).and_return('production-verify-token')
      expect(api_client).not_to receive(:subscribe_waba_webhook)

      expect { service.register_callback }
        .to raise_error(described_class::CallbackSetupError, /registry unavailable/)
    end

    it 'rejects a shared ingress without its matching verify token before provider mutation' do
      allow(GlobalConfigService).to receive(:load)
        .with(described_class::PUBLIC_INGRESS_CONFIG_KEY, nil).and_return('https://app.one-link.kz/webhooks/whatsapp')
      allow(GlobalConfigService).to receive(:load)
        .with(described_class::PUBLIC_INGRESS_VERIFY_TOKEN_CONFIG_KEY, nil).and_return(nil)
      expect(api_client).not_to receive(:subscribe_waba_webhook)

      expect { service.register_callback }
        .to raise_error(described_class::CallbackSetupError, /public webhook ingress verify token is required/)
    end

    it 'rejects an invalid shared ingress before mutating the provider callback' do
      allow(GlobalConfigService).to receive(:load)
        .with(described_class::PUBLIC_INGRESS_CONFIG_KEY, nil).and_return('http://dev.one-link.kz/webhooks/whatsapp')
      expect(api_client).not_to receive(:subscribe_waba_webhook)

      expect { service.register_callback }
        .to raise_error(described_class::CallbackSetupError, /public webhook ingress must be an HTTPS/)
    end

    it 'durably records an unknown callback outcome and schedules reconciliation' do
      error = Whatsapp::FacebookApiClient::WebhookCallbackOutcomeUnknownError.new('Callback outcome unknown')
      allow(api_client).to receive(:subscribe_waba_webhook).and_raise(error)

      with_modified_env FRONTEND_URL: 'https://one-link.kz' do
        expect { service.register_callback }.to raise_error(error)
      end

      recovery = channel.reload.provider_config[described_class::CALLBACK_RECOVERY_KEY]
      expect(recovery).to include(
        'state' => 'outcome_unknown',
        'waba_id' => waba_id,
        'callback_url' => 'https://one-link.kz/webhooks/whatsapp',
        'attempt_count' => 1,
        'subscribed_fields' => Whatsapp::FacebookApiClient::WEBHOOK_DEFAULT_FIELDS
      )
      expect(recovery['generation']).to be_present
      expect(recovery['verify_token_fingerprint']).to eq(OpenSSL::Digest::SHA256.hexdigest('test_verify_token'))
      expect(Whatsapp::WebhookCallbackReconciliationJob).to have_been_enqueued.with(channel.id, waba_id, recovery['generation'])
    end

    it 'preserves the channel recovery anchor when final persistence fails after the remote callback update' do
      recovery_service = Whatsapp::WebhookCallbackRecoveryService.new(channel, waba_id, secrets: [access_token])
      allow(Whatsapp::WebhookCallbackRecoveryService).to receive(:new).and_return(recovery_service)
      allow(api_client).to receive(:subscribe_waba_webhook).and_return({ 'success' => true })
      allow(recovery_service).to receive(:resolved!).and_raise(ActiveRecord::ConnectionNotEstablished, 'database unavailable')

      with_modified_env FRONTEND_URL: 'https://one-link.kz' do
        expect { service.register_callback }.to raise_error(described_class::PostMutationRecoveryError)
      end

      recovery = channel.reload.provider_config[described_class::CALLBACK_RECOVERY_KEY]
      expect(recovery).to include('state' => 'outcome_unknown', 'waba_id' => waba_id)
      expect(Whatsapp::WebhookCallbackReconciliationJob).to have_been_enqueued.with(channel.id, waba_id, recovery['generation'])
    end

    it 'does not replace a typed recovery error when persisting and scheduling recovery both fail' do
      recovery_service = instance_double(Whatsapp::WebhookCallbackRecoveryService)
      original_error = Whatsapp::FacebookApiClient::WebhookCallbackOutcomeUnknownError.new('Callback outcome unknown')
      allow(Whatsapp::WebhookCallbackRecoveryService).to receive(:new).and_return(recovery_service)
      allow(recovery_service).to receive(:updating!)
      allow(recovery_service).to receive(:outcome_unknown!).and_raise(ActiveRecord::ConnectionNotEstablished, 'database unavailable')
      allow(recovery_service).to receive(:generation).and_raise(ActiveRecord::ConnectionNotEstablished, 'database unavailable')
      allow(api_client).to receive(:subscribe_waba_webhook).and_raise(original_error)

      with_modified_env FRONTEND_URL: 'https://one-link.kz' do
        expect { service.register_callback }.to raise_error(original_error)
      end
    end

    it 'marks unresolved recovery as manual without overwriting a later resolved result' do
      config = channel.provider_config.deep_dup
      config[described_class::CALLBACK_RECOVERY_KEY] = { 'state' => 'outcome_unknown', 'waba_id' => waba_id }
      channel.update!(provider_config: config)

      service.require_manual_callback_recovery!(StandardError.new('still unknown'))

      expect(channel.reload.provider_config[described_class::CALLBACK_RECOVERY_KEY]['state']).to eq('manual_recovery_required')
      expect(channel).to be_reauthorization_required

      config = channel.provider_config.deep_dup
      config[described_class::CALLBACK_RECOVERY_KEY]['state'] = 'resolved'
      channel.update!(provider_config: config)
      service.require_manual_callback_recovery!(StandardError.new('stale retry'))
      expect(channel.reload.provider_config[described_class::CALLBACK_RECOVERY_KEY]['state']).to eq('resolved')
    end
  end

  describe '#register_callback_if_missing' do
    it 'rechecks under the WABA lock and avoids a duplicate callback mutation' do
      lock = instance_double(Whatsapp::WabaLock)
      lock_held = false
      allow(Whatsapp::WabaLock).to receive(:new).with(waba_id).and_return(lock)
      allow(lock).to receive(:with_lock) do |&block|
        lock_held = true
        block.call
      ensure
        lock_held = false
      end
      expect(api_client).to receive(:app_subscribed_to_waba?).with(waba_id) do
        expect(lock_held).to be(true)
        true
      end
      expect(api_client).not_to receive(:subscribe_waba_webhook)

      expect(service.register_callback_if_missing).to eq(:healthy)
    end

    it 'repairs the durable route even when the provider subscription is already healthy' do
      route_client = instance_double(Whatsapp::WebhookRouteRegistryClient, configured?: true)
      allow(Whatsapp::WebhookRouteRegistryClient).to receive(:new).and_return(route_client)
      allow(GlobalConfigService).to receive(:load)
        .with(described_class::PUBLIC_INGRESS_CONFIG_KEY, nil).and_return('https://app.one-link.kz/webhooks/whatsapp')
      allow(api_client).to receive(:app_subscribed_to_waba?).with(waba_id).and_return(true)

      expect(route_client).to receive(:register!).with(waba_id: waba_id, phone_number_id: '123456789')
      expect(service.register_callback_if_missing).to eq(:healthy)
    end
  end

  describe '#ensure_remote_route!' do
    it 'repairs the route under the WABA lock without mutating the provider subscription' do
      route_client = instance_double(Whatsapp::WebhookRouteRegistryClient, configured?: true)
      allow(Whatsapp::WebhookRouteRegistryClient).to receive(:new).and_return(route_client)
      allow(GlobalConfigService).to receive(:load)
        .with(described_class::PUBLIC_INGRESS_CONFIG_KEY, nil).and_return('https://app.one-link.kz/webhooks/whatsapp')

      expect(route_client).to receive(:register!).with(waba_id: waba_id, phone_number_id: '123456789')
      expect(api_client).not_to receive(:app_subscribed_to_waba?)
      expect(api_client).not_to receive(:subscribe_waba_webhook)

      expect(service.ensure_remote_route!).to eq(:healthy)
    end
  end

  describe '#register_phone_number_with_pin!' do
    it 'rejects a provider identity change that occurs before the WABA lock is acquired' do
      lock = instance_double(Whatsapp::WabaLock)
      allow(Whatsapp::WabaLock).to receive(:new).with(waba_id).and_return(lock)
      allow(lock).to receive(:with_lock) do |&block|
        channel.update!(provider_config: channel.provider_config.merge('phone_number_id' => 'rotated-phone'))
        block.call
      end
      expect(api_client).not_to receive(:register_phone_number)

      expect { service.register_phone_number_with_pin!('123456') }
        .to raise_error(described_class::StalePhoneRegistrationIdentityError)
    end
  end

  describe '#perform' do
    context 'when phone number is NOT verified (should register)' do
      before do
        allow(api_client).to receive(:phone_number_verified?).with('123456789').and_return(false)
        allow(SecureRandom).to receive(:random_number).with(900_000).and_return(123_456)
        allow(api_client).to receive(:register_phone_number).with('123456789', '223456')
        allow(api_client).to receive(:subscribe_waba_webhook)
          .with(waba_id, anything, 'test_verify_token').and_return({ 'success' => true })
        allow(channel).to receive(:save!)
      end

      it 'registers the phone number and sets up webhook' do
        with_modified_env FRONTEND_URL: 'https://one-link.kz' do
          expect(api_client).to receive(:register_phone_number).with('123456789', '223456')
          expect(api_client).to receive(:subscribe_waba_webhook)
            .with(waba_id, 'https://one-link.kz/webhooks/whatsapp', 'test_verify_token')
          service.perform
        end
      end
    end

    context 'when phone number IS verified AND fully provisioned (should NOT register)' do
      before do
        allow(api_client).to receive(:phone_number_verified?).with('123456789').and_return(true)
        allow(health_service).to receive(:fetch_health_status).and_return({
                                                                            platform_type: 'APPLICABLE',
                                                                            throughput: { level: 'APPLICABLE' }
                                                                          })
        allow(api_client).to receive(:subscribe_waba_webhook)
          .with(waba_id, anything, 'test_verify_token').and_return({ 'success' => true })
      end

      it 'does NOT register phone, but sets up webhook' do
        with_modified_env FRONTEND_URL: 'https://one-link.kz' do
          expect(api_client).not_to receive(:register_phone_number)
          expect(api_client).to receive(:subscribe_waba_webhook)
            .with(waba_id, 'https://one-link.kz/webhooks/whatsapp', 'test_verify_token')
          service.perform
        end
      end
    end

    context 'when initial standard signup forces registration' do
      let(:service) { described_class.new(channel, waba_id, access_token, strict: true, force_registration: true) }

      before do
        allow(api_client).to receive(:subscribe_waba_webhook).and_return({ 'success' => true })
        allow(api_client).to receive(:register_phone_number).and_return({ 'success' => true })
        allow(channel).to receive(:save!)
      end

      it 'subscribes the WABA, registers, and persists the PIN only after provider success' do
        with_modified_env FRONTEND_URL: 'https://one-link.kz' do
          expect(api_client).to receive(:subscribe_waba_webhook).ordered
          expect(api_client).to receive(:register_phone_number).ordered

          service.perform
        end

        expect(channel.reload.provider_config['verification_pin']).to be_present
      end

      it 'preserves a stored six-digit PIN with a leading zero' do
        channel.provider_config['verification_pin'] = '012345'

        with_modified_env FRONTEND_URL: 'https://one-link.kz' do
          expect(api_client).to receive(:register_phone_number).with('123456789', '012345')

          service.perform
        end
      end
    end

    context 'when phone number IS verified BUT needs registration (pending provisioning)' do
      before do
        allow(api_client).to receive(:phone_number_verified?).with('123456789').and_return(true)
        allow(health_service).to receive(:fetch_health_status).and_return({
                                                                            platform_type: 'NOT_APPLICABLE',
                                                                            throughput: { level: 'APPLICABLE' }
                                                                          })
        allow(SecureRandom).to receive(:random_number).with(900_000).and_return(123_456)
        allow(api_client).to receive(:register_phone_number).with('123456789', '223456')
        allow(api_client).to receive(:subscribe_waba_webhook)
          .with(waba_id, anything, 'test_verify_token').and_return({ 'success' => true })
        allow(channel).to receive(:save!)
      end

      it 'registers the phone number due to pending provisioning state' do
        with_modified_env FRONTEND_URL: 'https://one-link.kz' do
          expect(api_client).to receive(:register_phone_number).with('123456789', '223456')
          expect(api_client).to receive(:subscribe_waba_webhook)
            .with(waba_id, 'https://one-link.kz/webhooks/whatsapp', 'test_verify_token')
          service.perform
        end
      end
    end

    context 'when phone number needs registration due to throughput level' do
      before do
        allow(api_client).to receive(:phone_number_verified?).with('123456789').and_return(true)
        allow(health_service).to receive(:fetch_health_status).and_return({
                                                                            platform_type: 'APPLICABLE',
                                                                            throughput: { level: 'NOT_APPLICABLE' }
                                                                          })
        allow(SecureRandom).to receive(:random_number).with(900_000).and_return(123_456)
        allow(api_client).to receive(:register_phone_number).with('123456789', '223456')
        allow(api_client).to receive(:subscribe_waba_webhook)
          .with(waba_id, anything, 'test_verify_token').and_return({ 'success' => true })
        allow(channel).to receive(:save!)
      end

      it 'registers the phone number due to throughput not applicable' do
        with_modified_env FRONTEND_URL: 'https://one-link.kz' do
          expect(api_client).to receive(:register_phone_number).with('123456789', '223456')
          expect(api_client).to receive(:subscribe_waba_webhook)
            .with(waba_id, 'https://one-link.kz/webhooks/whatsapp', 'test_verify_token')
          service.perform
        end
      end
    end

    context 'when phone_number_verified? raises error' do
      before do
        allow(api_client).to receive(:phone_number_verified?).with('123456789').and_raise('API down')
        allow(health_service).to receive(:fetch_health_status).and_return({
                                                                            platform_type: 'APPLICABLE',
                                                                            throughput: { level: 'APPLICABLE' }
                                                                          })
        allow(SecureRandom).to receive(:random_number).with(900_000).and_return(123_456)
        allow(api_client).to receive(:register_phone_number)
        allow(api_client).to receive(:subscribe_waba_webhook).and_return({ 'success' => true })
        allow(channel).to receive(:save!)
      end

      it 'tries to register phone (due to verification error) and proceeds with webhook setup' do
        with_modified_env FRONTEND_URL: 'https://one-link.kz' do
          expect(api_client).to receive(:register_phone_number)
          expect(api_client).to receive(:subscribe_waba_webhook)
          expect { service.perform }.not_to raise_error
        end
      end
    end

    context 'when health service raises error' do
      before do
        allow(api_client).to receive(:phone_number_verified?).with('123456789').and_return(true)
        allow(health_service).to receive(:fetch_health_status).and_raise('Health API down')
        allow(api_client).to receive(:subscribe_waba_webhook).and_return({ 'success' => true })
      end

      it 'does not register phone (conservative approach) and proceeds with webhook setup' do
        with_modified_env FRONTEND_URL: 'https://one-link.kz' do
          expect(api_client).not_to receive(:register_phone_number)
          expect(api_client).to receive(:subscribe_waba_webhook)
          expect { service.perform }.not_to raise_error
        end
      end
    end

    context 'when phone registration fails (not blocking)' do
      before do
        allow(api_client).to receive(:phone_number_verified?).with('123456789').and_return(false)
        allow(SecureRandom).to receive(:random_number).with(900_000).and_return(123_456)
        allow(api_client).to receive(:register_phone_number).and_raise('Registration failed')
        allow(api_client).to receive(:subscribe_waba_webhook).and_return({ 'success' => true })
        allow(channel).to receive(:save!)
      end

      it 'continues with webhook setup even if registration fails' do
        with_modified_env FRONTEND_URL: 'https://one-link.kz' do
          expect(api_client).to receive(:register_phone_number)
          expect(api_client).to receive(:subscribe_waba_webhook)
          expect { service.perform }.not_to raise_error
        end
      end

      it 'raises in strict embedded-signup mode' do
        strict_service = described_class.new(channel, waba_id, access_token, strict: true)
        allow(api_client).to receive(:subscribe_waba_webhook).and_return({ 'success' => true })
        with_modified_env FRONTEND_URL: 'https://one-link.kz' do
          expect(api_client).to receive(:register_phone_number)
          expect(api_client).to receive(:subscribe_waba_webhook)
          expect { strict_service.perform }
            .to raise_error(Whatsapp::PhoneRegistrationService::Error, 'outcome_unknown')
        end
      end
    end

    context 'when webhook setup fails (should raise)' do
      before do
        allow(api_client).to receive(:phone_number_verified?).with('123456789').and_return(false)
        allow(SecureRandom).to receive(:random_number).with(900_000).and_return(123_456)
        allow(api_client).to receive(:register_phone_number)
        allow(api_client).to receive(:subscribe_waba_webhook).and_raise('Webhook failed')
      end

      it 'raises an error' do
        with_modified_env FRONTEND_URL: 'https://one-link.kz' do
          expect(api_client).not_to receive(:register_phone_number)
          expect(api_client).to receive(:subscribe_waba_webhook)
          expect { service.perform }.to raise_error(Whatsapp::WebhookSetupService::CallbackSetupError, /Webhook setup failed/)
        end
      end

      it 'preserves typed callback recovery errors for the signup lifecycle' do
        error = Whatsapp::FacebookApiClient::WebhookCallbackOutcomeUnknownError.new('Callback outcome unknown')
        allow(api_client).to receive(:subscribe_waba_webhook).and_raise(error)

        with_modified_env FRONTEND_URL: 'https://one-link.kz' do
          expect { service.perform }.to raise_error(error)
        end
      end

      it 'sanitizes credentials in logs and the raised error' do
        raw_error = "Webhook failed access_token=#{access_token} verify_token=test_verify_token"
        allow(api_client).to receive(:subscribe_waba_webhook).and_raise(raw_error)
        allow(Rails.logger).to receive(:error)

        with_modified_env FRONTEND_URL: 'https://one-link.kz' do
          expect { service.perform }
            .to raise_error(StandardError, 'Webhook setup failed: Webhook failed access_token=[FILTERED] verify_token=[FILTERED]')
        end

        expect(Rails.logger).not_to have_received(:error).with(include(access_token))
        expect(Rails.logger).not_to have_received(:error).with(include('test_verify_token'))
        recovery_error = channel.reload.provider_config.dig(described_class::CALLBACK_RECOVERY_KEY, 'last_error')
        expect(recovery_error).not_to include(access_token)
        expect(recovery_error).not_to include('test_verify_token')
      end
    end

    context 'when required parameters are missing' do
      it 'raises error when channel is nil' do
        service_invalid = described_class.new(nil, waba_id, access_token)
        expect { service_invalid.perform }.to raise_error(ArgumentError, 'Channel is required')
      end

      it 'raises error when waba_id is blank' do
        service_invalid = described_class.new(channel, '', access_token)
        expect { service_invalid.perform }.to raise_error(ArgumentError, 'WABA ID is required')
      end

      it 'raises error when access_token is blank' do
        service_invalid = described_class.new(channel, waba_id, '')
        expect { service_invalid.perform }.to raise_error(ArgumentError, 'Access token is required')
      end
    end

    context 'when PIN already exists' do
      before do
        channel.provider_config['verification_pin'] = 123_456
        allow(api_client).to receive(:phone_number_verified?).with('123456789').and_return(false)
        allow(api_client).to receive(:register_phone_number)
        allow(api_client).to receive(:subscribe_waba_webhook).and_return({ 'success' => true })
        allow(channel).to receive(:save!)
      end

      it 'reuses existing PIN' do
        with_modified_env FRONTEND_URL: 'https://one-link.kz' do
          expect(api_client).to receive(:register_phone_number).with('123456789', '123456')
          expect(SecureRandom).not_to receive(:random_number)
          service.perform
        end
      end
    end

    context 'when webhook setup fails and should trigger reauthorization' do
      before do
        allow(api_client).to receive(:phone_number_verified?).with('123456789').and_return(true)
        allow(api_client).to receive(:subscribe_waba_webhook).and_raise('Invalid access token')
      end

      it 'raises error with webhook setup failure message' do
        with_modified_env FRONTEND_URL: 'https://one-link.kz' do
          expect { service.perform }.to raise_error(/Webhook setup failed: Invalid access token/)
        end
      end

      it 'logs the webhook setup failure' do
        with_modified_env FRONTEND_URL: 'https://one-link.kz' do
          expect(Rails.logger).to receive(:error).with('[WHATSAPP] Webhook setup failed: Invalid access token')
          expect { service.perform }.to raise_error(/Webhook setup failed/)
        end
      end
    end

    context 'when used during reauthorization flow' do
      let(:existing_channel) do
        create(:channel_whatsapp,
               phone_number: '+1234567890',
               provider_config: {
                 'phone_number_id' => '123456789',
                 'webhook_verify_token' => 'existing_verify_token',
                 'business_id' => 'existing_business_id',
                 'waba_id' => 'existing_waba_id',
                 'source' => 'embedded_signup'
               },
               provider: 'whatsapp_cloud',
               sync_templates: false,
               validate_provider_config: false)
      end
      let(:new_access_token) { 'new_access_token' }
      let(:service_reauth) { described_class.new(existing_channel, waba_id, new_access_token) }

      before do
        allow(api_client).to receive(:phone_number_verified?).with('123456789').and_return(true)
        allow(health_service).to receive(:fetch_health_status).and_return({
                                                                            platform_type: 'APPLICABLE',
                                                                            throughput: { level: 'APPLICABLE' }
                                                                          })
        allow(api_client).to receive(:subscribe_waba_webhook)
          .with(waba_id, anything, 'test_verify_token').and_return({ 'success' => true })
      end

      it 'successfully reauthorizes with new access token' do
        with_modified_env FRONTEND_URL: 'https://one-link.kz' do
          expect(api_client).not_to receive(:register_phone_number)
          expect(api_client).to receive(:subscribe_waba_webhook)
            .with(waba_id, 'https://one-link.kz/webhooks/whatsapp', 'test_verify_token')
          service_reauth.perform
        end
      end

      it 'uses the existing webhook verify token during reauthorization' do
        with_modified_env FRONTEND_URL: 'https://one-link.kz' do
          expect(api_client).to receive(:subscribe_waba_webhook)
            .with(waba_id, anything, 'test_verify_token')
          service_reauth.perform
        end
      end
    end

    context 'when webhook setup is successful in creation flow' do
      before do
        allow(api_client).to receive(:phone_number_verified?).with('123456789').and_return(true)
        allow(health_service).to receive(:fetch_health_status).and_return({
                                                                            platform_type: 'APPLICABLE',
                                                                            throughput: { level: 'APPLICABLE' }
                                                                          })
        allow(api_client).to receive(:subscribe_waba_webhook)
          .with(waba_id, anything, 'test_verify_token').and_return({ 'success' => true })
      end

      it 'completes successfully without errors' do
        with_modified_env FRONTEND_URL: 'https://one-link.kz' do
          expect { service.perform }.not_to raise_error
        end
      end

      it 'does not log any errors' do
        with_modified_env FRONTEND_URL: 'https://one-link.kz' do
          expect(Rails.logger).not_to receive(:error)
          service.perform
        end
      end
    end

    context 'when another channel on the WABA uses coexistence' do
      before do
        channel.update!(provider_config: channel.provider_config.merge('business_account_id' => waba_id))
        sibling = create(
          :channel_whatsapp,
          account: channel.account,
          provider: 'whatsapp_cloud',
          sync_templates: false,
          validate_provider_config: false
        )
        sibling.update!(
          provider_config: sibling.provider_config.merge(
            'business_account_id' => waba_id,
            'embedded_signup_flow' => 'coexistence'
          )
        )
        allow(api_client).to receive(:phone_number_verified?).with('123456789').and_return(true)
        allow(api_client).to receive(:webhook_subscribed_fields)
          .with(coexistence: true)
          .and_return(%w[messages account_update smb_message_echoes calls history smb_app_state_sync])
        allow(api_client).to receive(:subscribe_waba_webhook).and_return({ 'success' => true })
      end

      it 'preserves coexistence webhook fields without treating the standard number as coexistence' do
        fields = %w[messages account_update smb_message_echoes calls history smb_app_state_sync]

        expect(api_client).to receive(:phone_number_verified?).with('123456789')
        expect(api_client).not_to receive(:register_phone_number)
        expect(api_client).to receive(:subscribe_waba_webhook)
          .with(waba_id, anything, 'test_verify_token', subscribed_fields: fields)

        service.perform
      end
    end

    context 'when the same-account coexistence sibling is pending deletion' do
      before do
        channel.update!(provider_config: channel.provider_config.merge('business_account_id' => waba_id))
        sibling = create(
          :channel_whatsapp,
          account: channel.account,
          provider: 'whatsapp_cloud',
          sync_templates: false,
          validate_provider_config: false
        )
        sibling.update!(
          provider_config: sibling.provider_config.merge(
            'business_account_id' => waba_id,
            'embedded_signup_flow' => 'coexistence'
          )
        )
        sibling.inbox.update!(deleting_at: Time.current)
        allow(api_client).to receive(:webhook_subscribed_fields)
          .with(coexistence: true)
          .and_return(%w[messages account_update smb_message_echoes calls history smb_app_state_sync])
        allow(api_client).to receive(:subscribe_waba_webhook).and_return({ 'success' => true })
      end

      it 'keeps coexistence subscription fields during the deleting lifecycle' do
        fields = %w[messages account_update smb_message_echoes calls history smb_app_state_sync]

        expect(api_client).to receive(:subscribe_waba_webhook)
          .with(waba_id, anything, 'test_verify_token', subscribed_fields: fields)

        service.register_callback
      end
    end

    context 'when WABA ownership spans multiple accounts' do
      before do
        foreign_channel = create(
          :channel_whatsapp,
          account: create(:account, limits: { non_web_inboxes: ChatwootApp.max_limit }),
          provider: 'whatsapp_cloud',
          sync_templates: false,
          validate_provider_config: false
        )
        foreign_channel.update!(
          provider_config: foreign_channel.provider_config.merge('business_account_id' => waba_id)
        )
      end

      it 'refuses to mutate the shared callback' do
        expect(api_client).not_to receive(:subscribe_waba_webhook)

        expect { service.register_callback }
          .to raise_error(RuntimeError, /WABA ownership spans multiple accounts/)
      end
    end

    context 'when a foreign WABA owner is pending deletion' do
      before do
        foreign_channel = create(
          :channel_whatsapp,
          account: create(:account, limits: { non_web_inboxes: ChatwootApp.max_limit }),
          provider: 'whatsapp_cloud',
          sync_templates: false,
          validate_provider_config: false
        )
        foreign_channel.update!(provider_config: foreign_channel.provider_config.merge('business_account_id' => waba_id))
        foreign_channel.inbox.update!(deleting_at: Time.current)
      end

      it 'keeps lifecycle ownership fail-closed' do
        expect(api_client).not_to receive(:subscribe_waba_webhook)

        expect { service.register_callback }
          .to raise_error(RuntimeError, /WABA ownership spans multiple accounts/)
      end
    end

    context 'with a coexistence channel' do
      before do
        config = channel.provider_config.merge('embedded_signup_flow' => 'coexistence')
        channel.update!(provider_config: config)
        allow(api_client).to receive(:webhook_subscribed_fields)
          .with(coexistence: true)
          .and_return(%w[messages account_update smb_message_echoes calls history smb_app_state_sync])
        allow(api_client).to receive(:subscribe_waba_webhook).and_return({ 'success' => true })
      end

      it 'never registers the business-app number and subscribes the coexistence fields' do
        fields = %w[messages account_update smb_message_echoes calls history smb_app_state_sync]

        expect(api_client).not_to receive(:phone_number_verified?)
        expect(api_client).not_to receive(:register_phone_number)
        expect(api_client).to receive(:subscribe_waba_webhook)
          .with(waba_id, anything, 'test_verify_token', subscribed_fields: fields)

        service.perform
      end
    end
  end
end
