# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join 'spec/models/concerns/reauthorizable_shared.rb'

RSpec.describe Channel::Whatsapp do
  before do
    allow(GlobalConfigService).to receive(:load).and_call_original
    allow(GlobalConfigService).to receive(:load).with('WHATSAPP_API_VERSION', 'v25.0').and_return('v22.0')
  end

  describe 'concerns' do
    let(:channel) { create(:channel_whatsapp) }

    before do
      stub_request(:post, 'https://waba.360dialog.io/v1/configs/webhook')
      stub_request(:get, 'https://waba.360dialog.io/v1/configs/templates')
    end

    it_behaves_like 'reauthorizable'

    context 'when prompt_reauthorization!' do
      it 'calls channel notifier mail for whatsapp' do
        admin_mailer = double
        mailer_double = double

        expect(AdministratorNotifications::ChannelNotificationsMailer).to receive(:with).and_return(admin_mailer)
        expect(admin_mailer).to receive(:whatsapp_disconnect).with(channel.inbox).and_return(mailer_double)
        expect(mailer_double).to receive(:deliver_later)

        channel.prompt_reauthorization!
      end

      it 'dispatches inbox_updated once when reauthorization becomes required' do
        admin_mailer = double
        mailer_double = double
        allow(AdministratorNotifications::ChannelNotificationsMailer).to receive(:with).and_return(admin_mailer)
        allow(admin_mailer).to receive(:whatsapp_disconnect).and_return(mailer_double)
        allow(mailer_double).to receive(:deliver_later)
        allow(Rails.configuration.dispatcher).to receive(:dispatch)

        with_modified_env ENABLE_INBOX_EVENTS: 'true' do
          channel.prompt_reauthorization!
          channel.prompt_reauthorization!
        end

        expect(Rails.configuration.dispatcher).to have_received(:dispatch).with(
          Events::Types::INBOX_UPDATED,
          anything,
          inbox: channel.inbox,
          changed_attributes: { 'reauthorization_required' => [false, true] }
        ).once
      end

      it 'dispatches inbox_updated when reauthorization is cleared' do
        admin_mailer = double
        mailer_double = double
        allow(AdministratorNotifications::ChannelNotificationsMailer).to receive(:with).and_return(admin_mailer)
        allow(admin_mailer).to receive(:whatsapp_disconnect).and_return(mailer_double)
        allow(mailer_double).to receive(:deliver_later)
        allow(Rails.configuration.dispatcher).to receive(:dispatch)

        with_modified_env ENABLE_INBOX_EVENTS: 'true' do
          channel.prompt_reauthorization!
          channel.reauthorized!
        end

        expect(Rails.configuration.dispatcher).to have_received(:dispatch).with(
          Events::Types::INBOX_UPDATED,
          anything,
          inbox: channel.inbox,
          changed_attributes: { 'reauthorization_required' => [true, false] }
        )
      end

      it 'keeps the recovery requirement durable when Redis state is lost' do
        channel.prompt_reauthorization!
        Redis::Alfred.delete(channel.send(:reauthorization_required_key))

        expect(channel.reload.provider_config['reauthorization_required']).to be(true)
        expect(channel.reauthorization_required?).to be(true)
      end

      it 'clears the durable recovery requirement after successful reauthorization' do
        channel.prompt_reauthorization!

        channel.reauthorized!

        expect(channel.reload.provider_config).not_to have_key('reauthorization_required')
        expect(channel.reauthorization_required?).to be(false)
      end

      it 'commits the durable clear before cache invalidation becomes observable' do
        channel.prompt_reauthorization!
        inbox = channel.inbox
        allow(channel).to receive(:inbox).and_return(inbox)
        expect(inbox).to receive(:update_account_cache) do
          expect(channel.reload.provider_config).not_to have_key('reauthorization_required')
        end

        channel.reauthorized!
      end

      it 'restores the durable requirement when clear side effects fail so the transition can retry' do
        channel.prompt_reauthorization!
        inbox = channel.inbox
        allow(channel).to receive(:inbox).and_return(inbox)
        allow(inbox).to receive(:update_account_cache).and_raise('cache unavailable')

        expect { channel.reauthorized! }.to raise_error('cache unavailable')
        expect(channel.reload.provider_config['reauthorization_required']).to be(true)

        allow(inbox).to receive(:update_account_cache).and_return(true)
        channel.reauthorized!

        expect(channel.reload.reauthorization_required?).to be(false)
      end
    end
  end

  describe 'validate_provider_config' do
    let(:channel) { build(:channel_whatsapp, provider: 'whatsapp_cloud', account: create(:account)) }

    it 'validates false when provider config is wrong' do
      stub_request(:get, 'https://graph.facebook.com/v22.0//message_templates').to_return(status: 401)
      expect(channel.save).to be(false)
    end

    it 'validates true when provider config is right' do
      stub_request(:get, 'https://graph.facebook.com/v22.0//message_templates')
        .to_return(status: 200,
                   body: { data: [{
                     id: '123456789', name: 'test_template'
                   }] }.to_json)
      expect(channel.save).to be(true)
    end
  end

  describe 'WABA routing ownership validation' do
    let(:account) { create(:account) }
    let(:waba_id) { "waba-routing-#{SecureRandom.hex(6)}" }

    def cloud_config(waba_id, flow: 'standard')
      {
        'api_key' => 'test_key',
        'phone_number_id' => SecureRandom.hex(6),
        'business_account_id' => waba_id,
        'source' => 'embedded_signup',
        'embedded_signup_flow' => flow
      }
    end

    def candidate_channel(account:, waba_id:, flow:)
      described_class.new(
        account: account,
        phone_number: "+1555#{SecureRandom.random_number(10**7).to_s.rjust(7, '0')}",
        provider: 'whatsapp_cloud',
        provider_config: cloud_config(waba_id, flow: flow)
      ).tap { |channel| allow(channel).to receive(:validate_provider_config) }
    end

    it 'rejects a WABA already owned by another account' do
      existing = create(:channel_whatsapp, account: create(:account), provider: 'whatsapp_cloud',
                                           validate_provider_config: false, sync_templates: false)
      existing.update!(provider_config: cloud_config(waba_id))
      candidate = candidate_channel(account: account, waba_id: waba_id, flow: 'standard')

      expect(candidate).not_to be_valid
      expect(candidate.errors.of_kind?(:provider_config, :invalid)).to be(true)
    end

    it 'keeps a pending-deletion inbox in lifecycle ownership checks' do
      existing = create(:channel_whatsapp, account: create(:account), provider: 'whatsapp_cloud',
                                           validate_provider_config: false, sync_templates: false)
      existing.update!(provider_config: cloud_config(waba_id))
      existing.inbox.update!(deleting_at: Time.current)
      candidate = candidate_channel(account: account, waba_id: waba_id, flow: 'standard')

      expect(candidate).not_to be_valid
      expect(candidate.errors.of_kind?(:provider_config, :invalid)).to be(true)
    end

    it 'keeps a suspended account as a lifecycle owner until remote teardown is confirmed' do
      suspended_account = create(:account, status: :suspended)
      existing = create(:channel_whatsapp, account: suspended_account, provider: 'whatsapp_cloud',
                                           validate_provider_config: false, sync_templates: false)
      existing.update!(provider_config: cloud_config(waba_id))

      candidate = candidate_channel(account: account, waba_id: waba_id, flow: 'standard')

      expect(candidate).not_to be_valid
      expect(candidate.errors.of_kind?(:provider_config, :invalid)).to be(true)
    end

    it 'allows a standard and coexistence sibling in the same account' do
      existing = create(:channel_whatsapp, account: account, provider: 'whatsapp_cloud',
                                           validate_provider_config: false, sync_templates: false)
      existing.update!(provider_config: cloud_config(waba_id))

      expect(candidate_channel(account: account, waba_id: waba_id, flow: 'coexistence')).to be_valid
    end

    it 'rejects a second coexistence channel for the same WABA' do
      existing = create(:channel_whatsapp, account: account, provider: 'whatsapp_cloud',
                                           validate_provider_config: false, sync_templates: false)
      existing.update!(provider_config: cloud_config(waba_id, flow: 'coexistence'))
      candidate = candidate_channel(account: account, waba_id: waba_id, flow: 'coexistence')

      expect(candidate).not_to be_valid
      expect(candidate.errors.of_kind?(:provider_config, :taken)).to be(true)
    end
  end

  describe 'webhook_verify_token' do
    before do
      # Stub webhook setup to prevent HTTP calls during channel creation
      setup_service = instance_double(Whatsapp::WebhookSetupService)
      allow(Whatsapp::WebhookSetupService).to receive(:new).and_return(setup_service)
      allow(setup_service).to receive(:perform)
    end

    it 'generates webhook_verify_token if not present' do
      channel = create(:channel_whatsapp,
                       provider_config: {
                         'webhook_verify_token' => nil,
                         'api_key' => 'test_key',
                         'business_account_id' => '123456789'
                       },
                       provider: 'whatsapp_cloud',
                       account: create(:account),
                       validate_provider_config: false,
                       sync_templates: false)

      expect(channel.provider_config['webhook_verify_token']).not_to be_nil
    end

    it 'does not generate webhook_verify_token if present' do
      channel = create(:channel_whatsapp,
                       provider: 'whatsapp_cloud',
                       provider_config: {
                         'webhook_verify_token' => '123',
                         'api_key' => 'test_key',
                         'business_account_id' => '123456789'
                       },
                       account: create(:account),
                       validate_provider_config: false,
                       sync_templates: false)

      expect(channel.provider_config['webhook_verify_token']).to eq '123'
    end
  end

  describe '#callback_webhook_url' do
    it 'uses the channel-bound default callback for manual Cloud setup' do
      channel = build_stubbed(
        :channel_whatsapp,
        provider: 'whatsapp_cloud',
        provider_config: { 'source' => 'manual' }
      )

      with_modified_env('FRONTEND_URL' => 'https://app.example.test') do
        expect(channel.callback_webhook_url)
          .to eq("https://app.example.test/webhooks/whatsapp?channel_id=#{channel.id}")
      end
    end

    it 'uses the global default callback for embedded Cloud setup' do
      channel = build_stubbed(
        :channel_whatsapp,
        provider: 'whatsapp_cloud',
        provider_config: { 'source' => 'embedded_signup' }
      )

      with_modified_env('FRONTEND_URL' => 'https://app.example.test') do
        expect(channel.callback_webhook_url).to eq('https://app.example.test/webhooks/whatsapp')
      end
    end

    it 'preserves the explicit phone callback for the legacy provider' do
      channel = build_stubbed(:channel_whatsapp, provider: 'default', phone_number: '+1234567890')

      with_modified_env('FRONTEND_URL' => 'https://app.example.test') do
        expect(channel.callback_webhook_url).to eq('https://app.example.test/webhooks/whatsapp/+1234567890')
      end
    end
  end

  describe '#store_token_health!' do
    let(:channel) { create(:channel_whatsapp, provider: 'whatsapp_cloud', validate_provider_config: false, sync_templates: false) }

    it 'stores safe token health metadata without removing provider credentials' do
      channel.store_token_health!('status' => 'healthy', 'never_expires' => true)

      expect(channel.reload.provider_config).to include(
        'api_key' => 'test_key',
        Channel::Whatsapp::TOKEN_HEALTH_CONFIG_KEY => {
          'status' => 'healthy',
          'never_expires' => true
        }
      )
    end

    it 'sanitizes nested credentials before provider-config persistence' do
      channel_token = channel.provider_config['api_key']
      channel.store_token_health!(
        'status' => 'invalid',
        'oauth_code' => 'one-time-code',
        'refresh_token' => 'refresh-secret',
        'error' => { 'message' => "access_token=#{channel_token} code=one-time-code" }
      )

      stored_health = channel.reload.provider_config[Channel::Whatsapp::TOKEN_HEALTH_CONFIG_KEY].to_json
      expect(stored_health).to include('invalid', '[FILTERED]')
      expect(stored_health).not_to include(channel_token, 'one-time-code', 'refresh-secret')
    end
  end

  describe '#store_provider_lifecycle_event!' do
    let(:channel) { create(:channel_whatsapp, provider: 'whatsapp_cloud', validate_provider_config: false, sync_templates: false) }

    it 'sanitizes lifecycle metadata before provider-config persistence' do
      channel.store_provider_lifecycle_event!(
        'fingerprint' => 'event-1',
        'oauth_code' => 'one-time-code',
        'details' => { 'refresh_token' => 'refresh-secret' }
      )

      stored_event = channel.reload.provider_config[Channel::Whatsapp::PROVIDER_LIFECYCLE_CONFIG_KEY].to_json
      expect(stored_event).to include('event-1')
      expect(stored_event).not_to include('one-time-code', 'refresh-secret')
    end
  end

  describe '#update_message_templates_cache!' do
    let(:channel) { create(:channel_whatsapp, provider: 'whatsapp_cloud', validate_provider_config: false, sync_templates: false) }

    it 'updates templates and invalidates the inbox cache key' do
      inbox = channel.inbox
      allow(inbox).to receive(:update_account_cache)
      allow(channel).to receive(:inbox).and_return(inbox)

      result = channel.update_message_templates_cache!([{ 'name' => 'appointment_confirmation' }])

      expect(result).to be(true)
      expect(channel.reload.message_templates).to eq([{ 'name' => 'appointment_confirmation' }])
      expect(channel.message_templates_last_updated).to be_present
      expect(inbox).to have_received(:update_account_cache)
    end
  end

  describe '#record_provider_configuration_error!' do
    let(:channel) { create(:channel_whatsapp, provider: 'whatsapp_cloud', validate_provider_config: false, sync_templates: false) }

    it 'stores the configuration error and prompts reauthorization' do
      channel.record_provider_configuration_error!('Token is missing WABA access', type: 'WhatsAppTokenHealth')

      expect(channel.reload.provider_config).to include(
        'authorization_status' => 'reauthorization_required',
        'authorization_error' => hash_including(
          'type' => 'WhatsAppTokenHealth',
          'message' => 'Token is missing WABA access'
        )
      )
      expect(channel.reauthorization_required?).to be(true)
    end

    it 'sanitizes authorization errors before provider-config persistence' do
      channel_token = channel.provider_config['api_key']
      channel.record_provider_configuration_error!(
        "access_token=#{channel_token} code=one-time-code",
        type: 'WhatsAppTokenHealth'
      )

      stored_error = channel.reload.provider_config['authorization_error'].to_json
      expect(stored_error).to include('[FILTERED]')
      expect(stored_error).not_to include(channel_token, 'one-time-code')
    end
  end

  describe 'webhook setup after creation' do
    let(:account) { create(:account) }
    let(:webhook_service) { instance_double(Whatsapp::WebhookSetupService) }

    before do
      allow(Whatsapp::WebhookSetupService).to receive(:new).and_return(webhook_service)
      allow(webhook_service).to receive(:perform)
    end

    context 'when channel is created through embedded signup' do
      it 'does not raise error if webhook setup fails' do
        allow(webhook_service).to receive(:perform).and_raise(StandardError, 'Webhook error')

        expect do
          create(:channel_whatsapp,
                 account: account,
                 provider: 'whatsapp_cloud',
                 provider_config: {
                   'source' => 'embedded_signup',
                   'business_account_id' => 'test_waba_id',
                   'api_key' => 'test_access_token'
                 },
                 validate_provider_config: false,
                 sync_templates: false)
        end.not_to raise_error
      end
    end

    context 'when channel is created through manual setup' do
      it 'setups webhooks via after_commit callback' do
        expect(Whatsapp::WebhookSetupService).to receive(:new).and_return(webhook_service)
        expect(webhook_service).to receive(:perform)

        # Explicitly set source to nil to test manual setup behavior (not embedded_signup)
        create(:channel_whatsapp,
               account: account,
               provider: 'whatsapp_cloud',
               provider_config: {
                 'business_account_id' => 'test_waba_id',
                 'api_key' => 'test_access_token',
                 'source' => nil
               },
               validate_provider_config: false,
               sync_templates: false)
      end
    end

    context 'when channel is created with different provider' do
      it 'does not setup webhooks for 360dialog provider' do
        expect(Whatsapp::WebhookSetupService).not_to receive(:new)

        create(:channel_whatsapp,
               account: account,
               provider: 'default',
               provider_config: {
                 'source' => 'embedded_signup',
                 'api_key' => 'test_360dialog_key'
               },
               validate_provider_config: false,
               sync_templates: false)
      end
    end
  end

  describe '#teardown_webhooks' do
    let(:account) { create(:account) }

    context 'when channel is whatsapp_cloud with embedded_signup' do
      it 'calls WebhookTeardownService on destroy' do
        # Mock the setup service to prevent HTTP calls during creation
        setup_service = instance_double(Whatsapp::WebhookSetupService)
        allow(Whatsapp::WebhookSetupService).to receive(:new).and_return(setup_service)
        allow(setup_service).to receive(:perform)

        channel = create(:channel_whatsapp,
                         account: account,
                         provider: 'whatsapp_cloud',
                         provider_config: {
                           'source' => 'embedded_signup',
                           'business_account_id' => 'test_waba_id',
                           'api_key' => 'test_access_token',
                           'phone_number_id' => '123456789'
                         },
                         validate_provider_config: false,
                         sync_templates: false)

        teardown_service = instance_double(Whatsapp::WebhookTeardownService)
        allow(Whatsapp::WebhookTeardownService).to receive(:new).with(channel).and_return(teardown_service)
        allow(teardown_service).to receive(:perform)

        channel.destroy

        expect(Whatsapp::WebhookTeardownService).to have_received(:new).with(channel)
        expect(teardown_service).to have_received(:perform)
      end
    end

    context 'when channel is not embedded_signup' do
      it 'calls WebhookTeardownService on destroy' do
        # Mock the setup service to prevent HTTP calls during creation
        setup_service = instance_double(Whatsapp::WebhookSetupService)
        allow(Whatsapp::WebhookSetupService).to receive(:new).and_return(setup_service)
        allow(setup_service).to receive(:perform)

        channel = create(:channel_whatsapp,
                         account: account,
                         provider: 'whatsapp_cloud',
                         provider_config: {
                           'business_account_id' => 'test_waba_id',
                           'api_key' => 'test_access_token'
                         },
                         validate_provider_config: false,
                         sync_templates: false)

        teardown_service = instance_double(Whatsapp::WebhookTeardownService)
        allow(Whatsapp::WebhookTeardownService).to receive(:new).with(channel).and_return(teardown_service)
        allow(teardown_service).to receive(:perform)

        channel.destroy

        expect(teardown_service).to have_received(:perform)
      end
    end
  end

  describe '#voice_enabled?' do
    let(:account) { create(:account) }

    before do
      setup_service = instance_double(Whatsapp::WebhookSetupService)
      allow(Whatsapp::WebhookSetupService).to receive(:new).and_return(setup_service)
      allow(setup_service).to receive(:perform)
    end

    it 'returns true only for embedded WhatsApp Cloud inboxes with calling enabled and account feature enabled' do
      account.enable_features!('whatsapp_call')

      channel = create(
        :channel_whatsapp,
        account: account,
        provider: 'whatsapp_cloud',
        provider_config: { 'source' => 'embedded_signup', 'calling_enabled' => true },
        validate_provider_config: false,
        sync_templates: false
      )

      expect(channel.voice_enabled?).to be true
    end

    it 'defaults to enabled when calling capability is known but no manual toggle exists' do
      account.enable_features!('whatsapp_call')

      channel = create(
        :channel_whatsapp,
        account: account,
        provider: 'whatsapp_cloud',
        provider_config: { 'source' => 'embedded_signup', 'calling_capable' => true },
        validate_provider_config: false,
        sync_templates: false
      )

      expect(channel.voice_enabled?).to be true
    end

    it 'respects an explicit manual disable even when calling capability is present' do
      account.enable_features!('whatsapp_call')

      channel = create(
        :channel_whatsapp,
        account: account,
        provider: 'whatsapp_cloud',
        provider_config: { 'source' => 'embedded_signup', 'calling_capable' => true, 'calling_enabled' => false },
        validate_provider_config: false,
        sync_templates: false
      )

      expect(channel.voice_enabled?).to be false
    end

    it 'returns false when the account feature is disabled' do
      channel = create(
        :channel_whatsapp,
        account: account,
        provider: 'whatsapp_cloud',
        provider_config: { 'source' => 'embedded_signup', 'calling_enabled' => true },
        validate_provider_config: false,
        sync_templates: false
      )

      expect(channel.voice_enabled?).to be false
    end

    it 'returns false for non embedded signup WhatsApp Cloud inboxes' do
      account.enable_features!('whatsapp_call')

      channel = create(
        :channel_whatsapp,
        account: account,
        provider: 'whatsapp_cloud',
        provider_config: { 'source' => 'manual', 'calling_enabled' => true },
        validate_provider_config: false,
        sync_templates: false
      )

      expect(channel.voice_enabled?).to be false
    end
  end

  describe '.provider_authorization_error' do
    it 'normalizes Meta invalid-token errors as reauthorization errors' do
      error = described_class.provider_authorization_error(
        error: {
          'message' => 'Error validating access token: Session has expired',
          'type' => 'OAuthException',
          'code' => 190,
          'fbtrace_id' => 'trace-190'
        }
      )

      expect(error).to include(
        'code' => 190,
        'type' => 'OAuthException',
        'message' => include('Error validating access token'),
        'fbtrace_id' => 'trace-190'
      )
    end

    it 'does not treat unrelated OAuth errors as reauthorization errors' do
      error = described_class.provider_authorization_error(
        error: {
          'message' => 'Unsupported post request. Object with ID does not exist',
          'type' => 'OAuthException',
          'code' => 100
        }
      )

      expect(error).to be_nil
    end
  end

  describe '#record_provider_authorization_error!' do
    it 'does not mark a WhatsApp Cloud channel for reauthorization when a live Meta health-check still passes' do
      channel = create(:channel_whatsapp, provider: 'whatsapp_cloud', validate_provider_config: false, sync_templates: false)
      health_check = instance_double(Meta::AuthorizationHealthCheckService, healthy?: true)
      allow(Meta::AuthorizationHealthCheckService).to receive(:new).with(channel).and_return(health_check)
      expect(channel).not_to receive(:prompt_reauthorization!)

      result = channel.record_provider_authorization_error!(
        error: {
          'message' => 'Error validating access token: transient Meta validation failure',
          'type' => 'OAuthException',
          'code' => 190
        }
      )

      expect(result).to be(false)
      expect(channel.reload.reauthorization_required?).to be(false)
      expect(channel.provider_authorization_error_recorded?).to be(false)
    end

    it 'clears stale WhatsApp Cloud provider authorization metadata when live Meta health-check passes' do
      channel = create(:channel_whatsapp, provider: 'whatsapp_cloud', validate_provider_config: false, sync_templates: false)
      allow(channel).to receive(:send_channel_reauthorization_email)
      channel.record_provider_configuration_error!('Error validating access token', code: 190, type: 'OAuthException')
      health_check = instance_double(Meta::AuthorizationHealthCheckService, healthy?: true)
      allow(Meta::AuthorizationHealthCheckService).to receive(:new).with(channel).and_return(health_check)

      result = channel.record_provider_authorization_error!(error: { 'message' => 'Error validating access token', 'code' => 190 })

      expect(result).to be(false)
      expect(channel.reload.reauthorization_required?).to be(false)
      expect(channel.provider_authorization_error_recorded?).to be(false)
    end

    it 'preserves a non-provider reauthorization flag when a live Meta health-check passes' do
      channel = create(:channel_whatsapp, provider: 'whatsapp_cloud', validate_provider_config: false, sync_templates: false)
      allow(channel).to receive(:send_channel_reauthorization_email)
      channel.prompt_reauthorization!
      health_check = instance_double(Meta::AuthorizationHealthCheckService, healthy?: true)
      allow(Meta::AuthorizationHealthCheckService).to receive(:new).with(channel).and_return(health_check)

      result = channel.record_provider_authorization_error!(error: { 'message' => 'Error validating access token', 'code' => 190 })

      expect(result).to be(false)
      expect(channel.reload.reauthorization_required?).to be(true)
      expect(channel.provider_authorization_error_recorded?).to be(false)
    end

    it 'does not prompt reauthorization again when the channel is already flagged' do
      channel = create(:channel_whatsapp, validate_provider_config: false, sync_templates: false)
      channel.prompt_reauthorization!
      allow(channel).to receive(:prompt_reauthorization!)

      channel.record_provider_authorization_error!(
        error: {
          'message' => 'Error validating access token: Session has expired',
          'type' => 'OAuthException',
          'code' => 190
        }
      )

      expect(channel).not_to have_received(:prompt_reauthorization!)
      expect(channel.reload.provider_authorization_error_recorded?).to be(true)
    end
  end

  describe '#setup_webhooks' do
    it 'redacts channel credentials before logging setup errors' do
      channel = create(:channel_whatsapp, provider: 'whatsapp_cloud', validate_provider_config: false, sync_templates: false)
      api_key = channel.provider_config['api_key']
      verify_token = channel.provider_config['webhook_verify_token']
      allow(channel).to receive(:perform_webhook_setup)
        .and_raise("provider error access_token=#{api_key} verify_token=#{verify_token}")
      allow(channel).to receive(:prompt_reauthorization!)
      allow(Rails.logger).to receive(:error)

      channel.setup_webhooks

      expect(Rails.logger).to have_received(:error).with(include('access_token=[FILTERED]', 'verify_token=[FILTERED]'))
      expect(Rails.logger).not_to have_received(:error).with(include(api_key))
      expect(Rails.logger).not_to have_received(:error).with(include(verify_token))
    end
  end
end
