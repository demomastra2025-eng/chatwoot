require 'rails_helper'

RSpec.describe Whatsapp::WebhookTeardownService do
  describe '#perform' do
    let(:channel) { create(:channel_whatsapp, validate_provider_config: false, sync_templates: false) }
    let(:service) { described_class.new(channel) }

    context 'when channel is whatsapp_cloud with embedded_signup' do
      before do
        # Stub webhook setup to prevent HTTP calls during channel update
        allow(channel).to receive(:setup_webhooks).and_return(true)

        channel.update!(
          provider: 'whatsapp_cloud',
          provider_config: {
            'source' => 'embedded_signup',
            'business_account_id' => 'test_waba_id',
            'api_key' => 'test_api_key'
          }
        )
      end

      it 'calls unsubscribe_waba_webhook on Facebook API client' do
        api_client = instance_double(Whatsapp::FacebookApiClient)
        allow(Whatsapp::FacebookApiClient).to receive(:new).with('test_api_key').and_return(api_client)
        allow(api_client).to receive(:unsubscribe_waba_webhook).with('test_waba_id')

        service.perform

        expect(api_client).to have_received(:unsubscribe_waba_webhook).with('test_waba_id')
      end

      it 'moves the shared WABA callback to a surviving Cloud channel' do
        sibling = create(
          :channel_whatsapp,
          account: channel.account,
          provider: 'whatsapp_cloud',
          validate_provider_config: false,
          sync_templates: false
        )
        sibling.update!(provider_config: sibling.provider_config.merge('business_account_id' => 'test_waba_id'))
        setup_service = instance_double(Whatsapp::WebhookSetupService, register_callback: true)
        allow(Whatsapp::WebhookSetupService).to receive(:new).with(sibling).and_return(setup_service)

        expect(Whatsapp::FacebookApiClient).not_to receive(:new)

        service.perform

        expect(setup_service).to have_received(:register_callback)
      end

      it 'refuses last-owner unsubscribe while a sibling inbox is pending deletion' do
        sibling = create(
          :channel_whatsapp,
          account: channel.account,
          provider: 'whatsapp_cloud',
          validate_provider_config: false,
          sync_templates: false
        )
        sibling.update!(provider_config: sibling.provider_config.merge('business_account_id' => 'test_waba_id'))
        sibling.inbox.update!(deleting_at: Time.current)

        expect(Whatsapp::WebhookSetupService).not_to receive(:new)
        expect(Whatsapp::FacebookApiClient).not_to receive(:new)

        expect { service.perform }.to raise_error(Whatsapp::WebhookTeardownService::WebhookHandoffError)
      end

      it 'does not hand off the callback within a suspended account' do
        sibling = create(
          :channel_whatsapp,
          account: channel.account,
          provider: 'whatsapp_cloud',
          validate_provider_config: false,
          sync_templates: false
        )
        sibling.update!(provider_config: sibling.provider_config.merge('business_account_id' => 'test_waba_id'))
        channel.account.update!(status: :suspended)
        api_client = instance_double(Whatsapp::FacebookApiClient, unsubscribe_waba_webhook: true)
        allow(Whatsapp::FacebookApiClient).to receive(:new).with('test_api_key').and_return(api_client)

        expect(Whatsapp::WebhookSetupService).not_to receive(:new)

        service.perform

        expect(api_client).to have_received(:unsubscribe_waba_webhook).with('test_waba_id')
      end

      it 'blocks channel deletion when the sibling callback handoff fails' do
        sibling = create(
          :channel_whatsapp,
          account: channel.account,
          provider: 'whatsapp_cloud',
          validate_provider_config: false,
          sync_templates: false
        )
        sibling.update!(provider_config: sibling.provider_config.merge('business_account_id' => 'test_waba_id'))
        setup_service = instance_double(Whatsapp::WebhookSetupService)
        allow(setup_service).to receive(:register_callback).and_raise(StandardError, 'handoff unavailable')
        allow(Whatsapp::WebhookSetupService).to receive(:new).with(sibling).and_return(setup_service)

        expect { channel.destroy! }.to raise_error(Whatsapp::WebhookTeardownService::WebhookHandoffError)
        expect(Channel::Whatsapp.exists?(channel.id)).to be(true)
      end

      it 'does not move or unsubscribe a WABA that also appears in another account' do
        sibling = create(
          :channel_whatsapp,
          account: create(:account),
          provider: 'whatsapp_cloud',
          validate_provider_config: false,
          sync_templates: false
        )
        sibling.update!(provider_config: sibling.provider_config.merge('business_account_id' => 'test_waba_id'))
        allow(Rails.logger).to receive(:error)

        expect(Whatsapp::WebhookSetupService).not_to receive(:new)
        expect(Whatsapp::FacebookApiClient).not_to receive(:new)

        expect { service.perform }.to raise_error(Whatsapp::WebhookTeardownService::WebhookHandoffError)

        expect(Rails.logger).to have_received(:error)
          .with('[WHATSAPP] Webhook teardown refused because WABA ownership spans multiple accounts')
      end

      it 'refuses teardown while a foreign WABA owner is pending deletion' do
        foreign_sibling = create(
          :channel_whatsapp,
          account: create(:account),
          provider: 'whatsapp_cloud',
          validate_provider_config: false,
          sync_templates: false
        )
        foreign_sibling.update!(provider_config: foreign_sibling.provider_config.merge('business_account_id' => 'test_waba_id'))
        foreign_sibling.inbox.update!(deleting_at: Time.current)

        expect(Whatsapp::WebhookSetupService).not_to receive(:new)
        expect(Whatsapp::FacebookApiClient).not_to receive(:new)

        expect { service.perform }.to raise_error(Whatsapp::WebhookTeardownService::WebhookHandoffError)
      end

      it 'refuses callback handoff when both local and cross-account siblings share the WABA' do
        local_sibling = create(
          :channel_whatsapp,
          account: channel.account,
          provider: 'whatsapp_cloud',
          validate_provider_config: false,
          sync_templates: false
        )
        local_sibling.update!(provider_config: local_sibling.provider_config.merge('business_account_id' => 'test_waba_id'))
        foreign_sibling = create(
          :channel_whatsapp,
          account: create(:account),
          provider: 'whatsapp_cloud',
          validate_provider_config: false,
          sync_templates: false
        )
        foreign_sibling.update!(provider_config: foreign_sibling.provider_config.merge('business_account_id' => 'test_waba_id'))

        expect(Whatsapp::WebhookSetupService).not_to receive(:new)
        expect(Whatsapp::FacebookApiClient).not_to receive(:new)

        expect { service.perform }.to raise_error(Whatsapp::WebhookTeardownService::WebhookHandoffError)
      end

      it 'blocks channel deletion when the final WABA unsubscribe fails' do
        api_client = instance_double(Whatsapp::FacebookApiClient)
        allow(Whatsapp::FacebookApiClient).to receive(:new).and_return(api_client)
        allow(api_client).to receive(:unsubscribe_waba_webhook).and_raise(StandardError, 'API Error')

        expect { channel.destroy! }.to raise_error(Whatsapp::WebhookTeardownService::WebhookTeardownError)
        expect(Channel::Whatsapp.exists?(channel.id)).to be(true)
      end
    end

    context 'when channel is not whatsapp_cloud' do
      before do
        channel.update!(provider: 'default')
      end

      it 'does not attempt to unsubscribe webhook' do
        expect(Whatsapp::FacebookApiClient).not_to receive(:new)

        service.perform
      end
    end

    context 'when channel is whatsapp_cloud but not embedded_signup' do
      before do
        channel.update!(
          provider: 'whatsapp_cloud',
          provider_config: { 'source' => 'manual' }
        )
      end

      it 'does not attempt to unsubscribe webhook' do
        expect(Whatsapp::FacebookApiClient).not_to receive(:new)

        service.perform
      end
    end

    context 'when required config is missing' do
      before do
        channel.update!(
          provider: 'whatsapp_cloud',
          provider_config: { 'source' => 'embedded_signup' }
        )
      end

      it 'does not attempt to unsubscribe webhook' do
        expect(Whatsapp::FacebookApiClient).not_to receive(:new)

        service.perform
      end
    end
  end
end
