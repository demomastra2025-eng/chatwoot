require 'rails_helper'

RSpec.describe 'Webhooks::WhatsappController', type: :request do
  let(:channel) { create(:channel_whatsapp, provider: 'whatsapp_cloud', sync_templates: false, validate_provider_config: false) }
  let(:client_secret) { 'test-whatsapp-secret' }
  let(:body) { { content: 'hello' }.to_json }
  let(:default_account_update_body) do
    {
      phone_number: channel.phone_number,
      object: 'whatsapp_business_account',
      entry: [{
        id: channel.provider_config['business_account_id'],
        changes: [{ field: 'account_update', value: { event: 'ACCOUNT_RECONNECTED' } }]
      }]
    }.to_json
  end

  def signature_for(payload, secret = client_secret)
    "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', secret, payload)}"
  end

  def post_whatsapp_webhook(path, payload, signature: signature_for(payload), env: { WHATSAPP_APP_SECRET: client_secret }, headers: {})
    with_modified_env env do
      post path,
           params: payload,
           headers: { 'CONTENT_TYPE' => 'application/json', 'X-Hub-Signature-256' => signature }.merge(headers)
    end
  end

  def post_unsigned_whatsapp_webhook(path, payload, env: { WHATSAPP_APP_SECRET: client_secret })
    with_modified_env env do
      post path,
           params: payload,
           headers: { 'CONTENT_TYPE' => 'application/json' }
    end
  end

  def stub_ingress_routing(rules:, targets:)
    allow(GlobalConfigService).to receive(:load).and_call_original
    allow(GlobalConfigService).to receive(:load)
      .with(Whatsapp::WebhookIngressRouter::RULES_CONFIG_KEY, '{}').and_return(rules)
    allow(GlobalConfigService).to receive(:load)
      .with(Whatsapp::WebhookIngressRouter::TARGETS_CONFIG_KEY, '{}').and_return(targets)
  end

  def stub_forward_receiver(destination:, secret: 'shared-internal-forward-secret')
    allow(GlobalConfigService).to receive(:load).and_call_original
    allow(GlobalConfigService).to receive(:load)
      .with(Whatsapp::WebhookIngressRouter::RECEIVER_DESTINATION_CONFIG_KEY, nil).and_return(destination)
    allow(GlobalConfigService).to receive(:load)
      .with(Whatsapp::WebhookIngressRouter::FORWARD_SECRET_CONFIG_KEY, nil).and_return(secret)
  end

  before do
    InstallationConfig.where(name: %w[WHATSAPP_APP_SECRET WHATSAPP_WEBHOOK_VERIFY_TOKEN]).delete_all
    GlobalConfig.clear_cache
  end

  describe 'GET /webhooks/verify' do
    it 'returns 401 when valid params are not present' do
      get "/webhooks/whatsapp/#{channel.phone_number}"
      expect(response).to have_http_status(:unauthorized)
    end

    it 'returns 401 when invalid params' do
      get "/webhooks/whatsapp/#{channel.phone_number}",
          params: { 'hub.challenge' => '123456', 'hub.mode' => 'subscribe', 'hub.verify_token' => 'invalid' }
      expect(response).to have_http_status(:unauthorized)
    end

    it 'returns challenge when valid params' do
      get "/webhooks/whatsapp/#{channel.phone_number}",
          params: { 'hub.challenge' => '123456', 'hub.mode' => 'subscribe', 'hub.verify_token' => channel.provider_config['webhook_verify_token'] }
      expect(response.body).to eq '123456'
    end

    it 'does not allow a query phone number to shadow the explicit callback route' do
      sibling = create(:channel_whatsapp, provider: 'whatsapp_cloud', sync_templates: false, validate_provider_config: false)

      get "/webhooks/whatsapp/#{channel.phone_number}",
          params: {
            'phone_number' => sibling.phone_number,
            'hub.challenge' => '123456',
            'hub.mode' => 'subscribe',
            'hub.verify_token' => channel.provider_config['webhook_verify_token']
          }

      expect(response.body).to eq '123456'
    end

    it 'returns 401 when the mode is missing or is not subscribe' do
      token = channel.provider_config['webhook_verify_token']

      get "/webhooks/whatsapp/#{channel.phone_number}",
          params: { 'hub.challenge' => '123456', 'hub.verify_token' => token }
      expect(response).to have_http_status(:unauthorized)

      get "/webhooks/whatsapp/#{channel.phone_number}",
          params: { 'hub.challenge' => '123456', 'hub.mode' => 'unsubscribe', 'hub.verify_token' => token }
      expect(response).to have_http_status(:unauthorized)
    end

    it 'returns 401 when the challenge is missing' do
      get "/webhooks/whatsapp/#{channel.phone_number}",
          params: { 'hub.mode' => 'subscribe', 'hub.verify_token' => channel.provider_config['webhook_verify_token'] }
      expect(response).to have_http_status(:unauthorized)
    end

    it 'verifies the default app callback with the global token' do
      with_modified_env WHATSAPP_WEBHOOK_VERIFY_TOKEN: 'global-verify-token' do
        get '/webhooks/whatsapp',
            params: {
              'phone_number' => channel.phone_number,
              'hub.challenge' => '654321',
              'hub.mode' => 'subscribe',
              'hub.verify_token' => 'global-verify-token'
            }
      end

      expect(response.body).to eq '654321'
    end

    it 'verifies a referenced manual callback with its channel token when the global token is absent' do
      with_modified_env WHATSAPP_WEBHOOK_VERIFY_TOKEN: nil do
        get '/webhooks/whatsapp',
            params: {
              'channel_id' => channel.id,
              'hub.challenge' => 'manual-challenge',
              'hub.mode' => 'subscribe',
              'hub.verify_token' => channel.provider_config['webhook_verify_token']
            }
      end

      expect(response.body).to eq 'manual-challenge'
    end

    it 'does not let one channel token verify another referenced manual callback' do
      sibling = create(:channel_whatsapp, provider: 'whatsapp_cloud', sync_templates: false, validate_provider_config: false)

      get '/webhooks/whatsapp',
          params: {
            'channel_id' => sibling.id,
            'hub.challenge' => 'manual-challenge',
            'hub.mode' => 'subscribe',
            'hub.verify_token' => channel.provider_config['webhook_verify_token']
          }

      expect(response).to have_http_status(:unauthorized)
    end

    it 'does not fall back to the global token for an unknown or inactive channel id' do
      with_modified_env WHATSAPP_WEBHOOK_VERIFY_TOKEN: 'global-verify-token' do
        [0, channel.id].each do |channel_id|
          channel.inbox.mark_pending_deletion! if channel_id == channel.id
          get '/webhooks/whatsapp',
              params: {
                'channel_id' => channel_id,
                'hub.challenge' => 'manual-challenge',
                'hub.mode' => 'subscribe',
                'hub.verify_token' => 'global-verify-token'
              }

          expect(response).to have_http_status(:unauthorized)
        end
      end
    end
  end

  describe 'POST /webhooks/whatsapp/{:phone_number}' do
    it 'accepts a signed WABA-level event on the default app callback' do
      allow(Webhooks::WhatsappEventsJob).to receive(:perform_later)
      expect(Webhooks::WhatsappEventsJob).to receive(:perform_later).with(anything, hash_including(hmac_verified: true))

      post_whatsapp_webhook('/webhooks/whatsapp', default_account_update_body)

      expect(response).to have_http_status(:success)
    end

    it 'adds a database-derived callback phone for old workers processing a default account update' do
      allow(Webhooks::WhatsappEventsJob).to receive(:perform_later)

      post_whatsapp_webhook('/webhooks/whatsapp', default_account_update_body)

      expect(Webhooks::WhatsappEventsJob).to have_received(:perform_later).with(
        hash_including('phone_number' => channel.phone_number),
        hash_including(hmac_verified: true, waba_scoped: true)
      )
    end

    it 'keeps the legacy worker route for lifecycle updates while the inbox is pending deletion' do
      channel.inbox.mark_pending_deletion!
      allow(Webhooks::WhatsappEventsJob).to receive(:perform_later)

      post_whatsapp_webhook('/webhooks/whatsapp', default_account_update_body)

      expect(Webhooks::WhatsappEventsJob).to have_received(:perform_later).with(
        hash_including('phone_number' => channel.phone_number),
        hash_including(hmac_verified: true, waba_scoped: true)
      )
    end

    it 'splits a multi-account default update into owner-bound legacy worker payloads' do
      sibling = create(
        :channel_whatsapp,
        account: create(:account, limits: { non_web_inboxes: ChatwootApp.max_limit }),
        provider: 'whatsapp_cloud',
        sync_templates: false,
        validate_provider_config: false
      )
      sibling.update!(provider_config: sibling.provider_config.merge('business_account_id' => 'second-waba-id'))
      payload = {
        object: 'whatsapp_business_account',
        entry: [channel, sibling].map do |item|
          {
            id: item.provider_config['business_account_id'],
            changes: [{ field: 'account_update', value: { event: 'ACCOUNT_RECONNECTED' } }]
          }
        end
      }.to_json
      enqueued_payloads = []
      allow(Webhooks::WhatsappEventsJob).to receive(:perform_later) do |job_payload, _context|
        enqueued_payloads << job_payload
      end

      post_whatsapp_webhook('/webhooks/whatsapp', payload)

      expect(response).to have_http_status(:success)
      expect(enqueued_payloads.map { |job_payload| job_payload[:phone_number] })
        .to contain_exactly(channel.phone_number, sibling.phone_number)
      expect(enqueued_payloads.map { |job_payload| job_payload.dig(:entry, 0, :id) })
        .to contain_exactly(channel.provider_config['business_account_id'], sibling.provider_config['business_account_id'])
    end

    it 'routes one WABA to both DEV OneLink and Widget without processing it in production' do
      waba_id = channel.provider_config['business_account_id']
      stub_ingress_routing(
        rules: { waba_id => %w[dev widget] },
        targets: {
          'dev' => 'https://dev.one-link.kz/webhooks/whatsapp',
          'widget' => 'https://medelement.one-link.kz/webhooks/meta/whatsapp'
        }
      )
      allow(Webhooks::WhatsappEventsJob).to receive(:perform_later)
      allow(Webhooks::WhatsappForwardJob).to receive(:perform_later)

      post_whatsapp_webhook('/webhooks/whatsapp', default_account_update_body)

      expect(response).to have_http_status(:success)
      expect(Webhooks::WhatsappEventsJob).not_to have_received(:perform_later)
      expect(Webhooks::WhatsappForwardJob).to have_received(:perform_later)
        .with(hash_including('entry' => [hash_including('id' => waba_id)]), 'dev')
      expect(Webhooks::WhatsappForwardJob).to have_received(:perform_later)
        .with(hash_including('entry' => [hash_including('id' => waba_id)]), 'widget')
    end

    it 'processes a signed forwarded delivery locally instead of routing it back to DEV' do
      waba_id = channel.provider_config['business_account_id']
      stub_ingress_routing(
        rules: { waba_id => ['dev'] },
        targets: { 'dev' => 'https://dev.one-link.kz/webhooks/whatsapp' }
      )
      allow(Webhooks::WhatsappEventsJob).to receive(:perform_later)
      allow(Webhooks::WhatsappForwardJob).to receive(:perform_later)
      stub_forward_receiver(destination: 'dev')
      forwarded_signature = Whatsapp::WebhookIngressRouter.forwarded_signature(
        secret: 'shared-internal-forward-secret',
        destination: 'dev',
        body: default_account_update_body
      )

      post_whatsapp_webhook(
        '/webhooks/whatsapp',
        default_account_update_body,
        headers: {
          Whatsapp::WebhookIngressRouter::FORWARDED_HEADER => '1',
          Whatsapp::WebhookIngressRouter::FORWARDED_DESTINATION_HEADER => 'dev',
          Whatsapp::WebhookIngressRouter::FORWARDED_SIGNATURE_HEADER => forwarded_signature
        }
      )

      expect(response).to have_http_status(:success)
      expect(Webhooks::WhatsappEventsJob).to have_received(:perform_later).with(
        hash_including('entry' => [hash_including('id' => waba_id)]),
        hash_including(hmac_verified: true, waba_scoped: true)
      )
      expect(Webhooks::WhatsappForwardJob).not_to have_received(:perform_later)
    end

    it 'rejects a forged forwarded marker before dispatch' do
      allow(Webhooks::WhatsappEventsJob).to receive(:perform_later)
      allow(Webhooks::WhatsappForwardJob).to receive(:perform_later)
      stub_forward_receiver(destination: 'dev')

      post_whatsapp_webhook(
        '/webhooks/whatsapp',
        default_account_update_body,
        headers: {
          Whatsapp::WebhookIngressRouter::FORWARDED_HEADER => '1',
          Whatsapp::WebhookIngressRouter::FORWARDED_DESTINATION_HEADER => 'dev',
          Whatsapp::WebhookIngressRouter::FORWARDED_SIGNATURE_HEADER => 'sha256=invalid'
        }
      )

      expect(response).to have_http_status(:unauthorized)
      expect(Webhooks::WhatsappEventsJob).not_to have_received(:perform_later)
      expect(Webhooks::WhatsappForwardJob).not_to have_received(:perform_later)
    end

    it 'rejects a valid forwarded delivery targeted to another runtime' do
      allow(Webhooks::WhatsappEventsJob).to receive(:perform_later)
      allow(Webhooks::WhatsappForwardJob).to receive(:perform_later)
      stub_forward_receiver(destination: 'widget')
      forwarded_signature = Whatsapp::WebhookIngressRouter.forwarded_signature(
        secret: 'shared-internal-forward-secret',
        destination: 'dev',
        body: default_account_update_body
      )

      post_whatsapp_webhook(
        '/webhooks/whatsapp',
        default_account_update_body,
        headers: {
          Whatsapp::WebhookIngressRouter::FORWARDED_HEADER => '1',
          Whatsapp::WebhookIngressRouter::FORWARDED_DESTINATION_HEADER => 'dev',
          Whatsapp::WebhookIngressRouter::FORWARDED_SIGNATURE_HEADER => forwarded_signature
        }
      )

      expect(response).to have_http_status(:unauthorized)
      expect(Webhooks::WhatsappEventsJob).not_to have_received(:perform_later)
      expect(Webhooks::WhatsappForwardJob).not_to have_received(:perform_later)
    end

    it 'rejects a forwarded delivery when the internal secret is not configured' do
      allow(Webhooks::WhatsappEventsJob).to receive(:perform_later)
      allow(Webhooks::WhatsappForwardJob).to receive(:perform_later)
      stub_forward_receiver(destination: 'dev', secret: nil)

      post_whatsapp_webhook(
        '/webhooks/whatsapp',
        default_account_update_body,
        headers: {
          Whatsapp::WebhookIngressRouter::FORWARDED_HEADER => '1',
          Whatsapp::WebhookIngressRouter::FORWARDED_DESTINATION_HEADER => 'dev',
          Whatsapp::WebhookIngressRouter::FORWARDED_SIGNATURE_HEADER => 'sha256=invalid'
        }
      )

      expect(response).to have_http_status(:unauthorized)
      expect(Webhooks::WhatsappEventsJob).not_to have_received(:perform_later)
      expect(Webhooks::WhatsappForwardJob).not_to have_received(:perform_later)
    end

    it 'splits a mixed Meta batch before routing it to isolated owners' do
      remote_waba_id = '999999999999'
      payload = {
        object: 'whatsapp_business_account',
        entry: [
          {
            id: channel.provider_config['business_account_id'],
            changes: [{ field: 'messages', value: { messages: [{ id: 'wamid.prod' }] } }]
          },
          {
            id: remote_waba_id,
            changes: [{ field: 'messages', value: { messages: [{ id: 'wamid.widget' }] } }]
          }
        ]
      }.to_json
      stub_ingress_routing(
        rules: { remote_waba_id => ['widget'] },
        targets: { 'widget' => 'https://medelement.one-link.kz/webhooks/meta/whatsapp' }
      )
      allow(Webhooks::WhatsappEventsJob).to receive(:perform_later)
      allow(Webhooks::WhatsappForwardJob).to receive(:perform_later)

      post_whatsapp_webhook('/webhooks/whatsapp', payload)

      expect(response).to have_http_status(:success)
      expect(Webhooks::WhatsappEventsJob).to have_received(:perform_later).with(
        hash_including('entry' => [hash_including('id' => channel.provider_config['business_account_id'])]),
        hash_including(waba_account_ids: { channel.provider_config['business_account_id'] => channel.account_id })
      )
      expect(Webhooks::WhatsappForwardJob).to have_received(:perform_later).with(
        hash_including('entry' => [hash_including('id' => remote_waba_id)]),
        'widget'
      )
    end

    it 'ignores a suspended cross-account WABA claim at the signed ingress boundary' do
      active_secret = 'active-owner-app-secret'
      waba_id = channel.provider_config['business_account_id']
      channel.update!(provider_config: channel.provider_config.merge('app_secret' => active_secret))
      stale_channel = create(
        :channel_whatsapp,
        account: create(:account, status: :suspended, limits: { non_web_inboxes: ChatwootApp.max_limit }),
        provider: 'whatsapp_cloud',
        validate_provider_config: false,
        sync_templates: false
      )
      stale_channel.update!(
        provider_config: stale_channel.provider_config.merge(
          'business_account_id' => waba_id,
          'app_secret' => 'stale-owner-app-secret'
        )
      )
      expected_verification_context = {
        hmac_verified: true,
        channel_id: nil,
        channel_identity: {},
        waba_account_ids: { waba_id => channel.account_id },
        waba_scoped: true
      }
      expect(Webhooks::WhatsappEventsJob).to receive(:perform_later).with(anything, expected_verification_context)

      post_whatsapp_webhook(
        '/webhooks/whatsapp',
        default_account_update_body,
        signature: signature_for(default_account_update_body, active_secret),
        env: {}
      )

      expect(response).to have_http_status(:success)
    end

    it 'keeps a pending-deletion cross-account WABA claim in the signed ownership proof' do
      active_secret = 'active-owner-app-secret'
      waba_id = channel.provider_config['business_account_id']
      channel.update!(provider_config: channel.provider_config.merge('app_secret' => active_secret))
      pending_channel = create(
        :channel_whatsapp,
        account: create(:account, limits: { non_web_inboxes: ChatwootApp.max_limit }),
        provider: 'whatsapp_cloud',
        validate_provider_config: false,
        sync_templates: false
      )
      pending_channel.update!(provider_config: pending_channel.provider_config.merge('business_account_id' => waba_id))
      pending_channel.inbox.update!(deleting_at: Time.current)
      allow(Webhooks::WhatsappEventsJob).to receive(:perform_later)

      post_whatsapp_webhook(
        '/webhooks/whatsapp',
        default_account_update_body,
        signature: signature_for(default_account_update_body, active_secret),
        env: {}
      )

      expect(response).to have_http_status(:success)
      expect(Webhooks::WhatsappEventsJob).to have_received(:perform_later).with(
        anything,
        hmac_verified: true,
        channel_id: nil,
        channel_identity: {},
        waba_account_ids: { waba_id => nil },
        waba_scoped: true
      )
    end

    it 'does not authenticate a metadata-only default callback with a default provider secret' do
      provider_secret = 'default-provider-secret'
      channel.update!(provider: 'default', provider_config: channel.provider_config.merge('app_secret' => provider_secret))
      payload = {
        object: 'whatsapp_business_account',
        entry: [{
          changes: [{
            field: 'messages',
            value: {
              metadata: {
                display_phone_number: channel.phone_number.delete_prefix('+'),
                phone_number_id: channel.provider_config['phone_number_id']
              }
            }
          }]
        }]
      }.to_json
      allow(Webhooks::WhatsappEventsJob).to receive(:perform_later)

      post_whatsapp_webhook(
        '/webhooks/whatsapp',
        payload,
        signature: signature_for(payload, provider_secret),
        env: {}
      )

      expect(response).to have_http_status(:unauthorized)
      expect(Webhooks::WhatsappEventsJob).not_to have_received(:perform_later)
    end

    it 'verifies a default WABA callback when multiple phone channels share the same WABA' do
      shared_secret = '[REDACTED]'
      channel.update!(provider_config: channel.provider_config.merge('app_secret' => shared_secret))
      sibling = create(
        :channel_whatsapp,
        account: channel.account,
        provider: 'whatsapp_cloud',
        validate_provider_config: false,
        sync_templates: false
      )
      sibling.update!(
        provider_config: sibling.provider_config.merge(
          'business_account_id' => channel.provider_config['business_account_id'],
          'app_secret' => shared_secret
        )
      )
      allow(Webhooks::WhatsappEventsJob).to receive(:perform_later)

      post_whatsapp_webhook(
        '/webhooks/whatsapp',
        default_account_update_body,
        signature: signature_for(default_account_update_body, shared_secret),
        env: {}
      )

      expect(response).to have_http_status(:success)
      expect(Webhooks::WhatsappEventsJob).to have_received(:perform_later).with(anything, hash_including(hmac_verified: true))
    end

    it 'accepts a trusted same-WABA secret when a sibling credential is missing' do
      trusted_secret = 'trusted-waba-app-secret'
      channel.update!(provider_config: channel.provider_config.merge('app_secret' => trusted_secret))
      sibling = create(
        :channel_whatsapp,
        account: channel.account,
        provider: 'whatsapp_cloud',
        validate_provider_config: false,
        sync_templates: false
      )
      sibling.update!(
        provider_config: sibling.provider_config.except('app_secret').merge(
          'business_account_id' => channel.provider_config['business_account_id']
        )
      )
      allow(Webhooks::WhatsappEventsJob).to receive(:perform_later)

      post_whatsapp_webhook(
        '/webhooks/whatsapp',
        default_account_update_body,
        signature: signature_for(default_account_update_body, trusted_secret),
        env: {}
      )

      expect(response).to have_http_status(:success)
      expect(Webhooks::WhatsappEventsJob).to have_received(:perform_later).with(anything, hash_including(hmac_verified: true))
    end

    it 'rejects a sibling channel secret on an explicit phone callback' do
      sibling_secret = 'same-waba-sibling-secret'
      sibling = create(
        :channel_whatsapp,
        account: channel.account,
        provider: 'whatsapp_cloud',
        validate_provider_config: false,
        sync_templates: false
      )
      sibling.update!(
        provider_config: sibling.provider_config.merge(
          'business_account_id' => channel.provider_config['business_account_id'],
          'app_secret' => sibling_secret
        )
      )
      allow(Webhooks::WhatsappEventsJob).to receive(:perform_later)

      post_whatsapp_webhook(
        "/webhooks/whatsapp/#{channel.phone_number}",
        default_account_update_body,
        signature: signature_for(default_account_update_body, sibling_secret),
        env: {}
      )

      expect(response).to have_http_status(:unauthorized)
      expect(Webhooks::WhatsappEventsJob).not_to have_received(:perform_later)
    end

    it 'rejects payload metadata for a sibling phone on an explicit callback route' do
      route_secret = 'explicit-route-secret'
      channel.update!(provider_config: channel.provider_config.merge('app_secret' => route_secret))
      sibling = create(
        :channel_whatsapp,
        account: channel.account,
        provider: 'whatsapp_cloud',
        validate_provider_config: false,
        sync_templates: false
      )
      sibling.update!(
        provider_config: sibling.provider_config.merge(
          'business_account_id' => channel.provider_config['business_account_id'],
          'phone_number_id' => 'sibling-phone-number-id'
        )
      )
      payload = {
        object: 'whatsapp_business_account',
        entry: [{
          id: channel.provider_config['business_account_id'],
          changes: [{
            field: 'messages',
            value: {
              metadata: {
                display_phone_number: sibling.phone_number.delete_prefix('+'),
                phone_number_id: sibling.provider_config['phone_number_id']
              }
            }
          }]
        }]
      }.to_json
      allow(Webhooks::WhatsappEventsJob).to receive(:perform_later)

      post_whatsapp_webhook(
        "/webhooks/whatsapp/#{channel.phone_number}",
        payload,
        signature: signature_for(payload, route_secret),
        env: {}
      )

      expect(response).to have_http_status(:unauthorized)
      expect(Webhooks::WhatsappEventsJob).not_to have_received(:perform_later)
    end

    it 'rejects a signed explicit callback without a WABA identity' do
      route_secret = 'explicit-route-secret'
      channel.update!(provider_config: channel.provider_config.merge('app_secret' => route_secret))
      payload = {
        object: 'whatsapp_business_account',
        entry: [{ changes: [{ field: 'account_update', value: { event: 'ACCOUNT_RECONNECTED' } }] }]
      }.to_json
      allow(Webhooks::WhatsappEventsJob).to receive(:perform_later)

      post_whatsapp_webhook(
        "/webhooks/whatsapp/#{channel.phone_number}",
        payload,
        signature: signature_for(payload, route_secret),
        env: {}
      )

      expect(response).to have_http_status(:unauthorized)
      expect(Webhooks::WhatsappEventsJob).not_to have_received(:perform_later)
    end

    it 'accepts a trusted same-account sibling secret on the default WABA callback' do
      sibling_secret = 'same-account-sibling-secret'
      sibling = create(
        :channel_whatsapp,
        account: channel.account,
        provider: 'whatsapp_cloud',
        validate_provider_config: false,
        sync_templates: false
      )
      sibling.update!(
        provider_config: sibling.provider_config.merge(
          'business_account_id' => channel.provider_config['business_account_id'],
          'app_secret' => sibling_secret
        )
      )
      payload = {
        object: 'whatsapp_business_account',
        entry: [{
          id: channel.provider_config['business_account_id'],
          changes: [{
            field: 'messages',
            value: {
              metadata: {
                display_phone_number: channel.phone_number.delete_prefix('+'),
                phone_number_id: channel.provider_config['phone_number_id']
              }
            }
          }]
        }]
      }.to_json
      allow(Webhooks::WhatsappEventsJob).to receive(:perform_later)

      post_whatsapp_webhook(
        '/webhooks/whatsapp',
        payload,
        signature: signature_for(payload, sibling_secret),
        env: {}
      )

      expect(response).to have_http_status(:success)
      expect(Webhooks::WhatsappEventsJob).to have_received(:perform_later).with(anything, hash_including(hmac_verified: true))
    end

    it 'authenticates the full WABA secret union but keeps cross-account metadata routing ambiguous' do
      victim_secret = 'victim-app-secret'
      untrusted_secret = 'untrusted-app-secret'
      waba_id = channel.provider_config['business_account_id']
      channel.update!(provider_config: channel.provider_config.merge('app_secret' => victim_secret))
      other_channel = create(
        :channel_whatsapp,
        account: create(:account, limits: { non_web_inboxes: ChatwootApp.max_limit }),
        provider: 'whatsapp_cloud',
        validate_provider_config: false,
        sync_templates: false
      )
      other_channel.update!(
        provider_config: other_channel.provider_config.merge('business_account_id' => waba_id, 'app_secret' => untrusted_secret)
      )
      allow(Webhooks::WhatsappEventsJob).to receive(:perform_later)
      channel_body = {
        object: 'whatsapp_business_account',
        entry: [{
          id: waba_id,
          changes: [{
            field: 'messages',
            value: {
              metadata: {
                display_phone_number: channel.phone_number.delete_prefix('+'),
                phone_number_id: channel.provider_config['phone_number_id']
              }
            }
          }]
        }]
      }.to_json

      post_whatsapp_webhook(
        '/webhooks/whatsapp',
        channel_body,
        signature: signature_for(channel_body, untrusted_secret),
        env: {}
      )

      expect(response).to have_http_status(:success)
      expect(Webhooks::WhatsappEventsJob).to have_received(:perform_later).with(
        anything,
        hmac_verified: true,
        channel_id: nil,
        channel_identity: {},
        waba_account_ids: { waba_id => nil },
        waba_scoped: true
      )
    end

    it 'authenticates an ambiguous metadata-free WABA callback but leaves dispatch fail-closed' do
      waba_id = channel.provider_config['business_account_id']
      other_secret = 'other-account-app-secret'
      other_channel = create(
        :channel_whatsapp,
        account: create(:account, limits: { non_web_inboxes: ChatwootApp.max_limit }),
        provider: 'whatsapp_cloud',
        validate_provider_config: false,
        sync_templates: false
      )
      other_channel.update!(
        provider_config: other_channel.provider_config.merge('business_account_id' => waba_id, 'app_secret' => other_secret)
      )
      payload = {
        object: 'whatsapp_business_account',
        entry: [{ id: waba_id, changes: [{ field: 'account_update', value: { event: 'ACCOUNT_RECONNECTED' } }] }]
      }.to_json
      allow(Webhooks::WhatsappEventsJob).to receive(:perform_later)

      post_whatsapp_webhook(
        '/webhooks/whatsapp',
        payload,
        signature: signature_for(payload, other_secret),
        env: {}
      )

      expect(response).to have_http_status(:success)
      expect(Webhooks::WhatsappEventsJob).to have_received(:perform_later).with(anything, hash_including(hmac_verified: true))
    end

    it 'accepts a signed WABA batch containing metadata for sibling phone numbers' do
      stub_ingress_routing(rules: {}, targets: {})
      waba_id = channel.provider_config['business_account_id']
      app_secret = 'shared-waba-app-secret'
      channel.update!(provider_config: channel.provider_config.merge('app_secret' => app_secret))
      sibling = create(
        :channel_whatsapp,
        account: channel.account,
        provider: 'whatsapp_cloud',
        validate_provider_config: false,
        sync_templates: false
      )
      sibling.update!(
        provider_config: sibling.provider_config.merge(
          'business_account_id' => waba_id,
          'app_secret' => app_secret
        )
      )
      payload = {
        object: 'whatsapp_business_account',
        entry: [{
          id: waba_id,
          changes: [channel, sibling].map do |candidate|
            {
              field: 'messages',
              value: {
                metadata: {
                  display_phone_number: candidate.phone_number.delete_prefix('+'),
                  phone_number_id: candidate.provider_config['phone_number_id']
                }
              }
            }
          end
        }]
      }.to_json
      allow(Webhooks::WhatsappEventsJob).to receive(:perform_later)

      post_whatsapp_webhook(
        '/webhooks/whatsapp',
        payload,
        signature: signature_for(payload, app_secret),
        env: {}
      )

      expect(response).to have_http_status(:success)
      expect(Webhooks::WhatsappEventsJob).to have_received(:perform_later).with(anything, hash_including(hmac_verified: true))
    end

    it 'rejects a metadata-free multi-WABA batch unless every WABA shares the signing secret' do
      first_secret = 'first-waba-secret'
      second_secret = 'second-waba-secret'
      channel.update!(provider_config: channel.provider_config.merge('app_secret' => first_secret))
      second_channel = create(
        :channel_whatsapp,
        account: create(:account, limits: { non_web_inboxes: ChatwootApp.max_limit }),
        provider: 'whatsapp_cloud',
        validate_provider_config: false,
        sync_templates: false
      )
      second_channel.update!(
        provider_config: second_channel.provider_config.merge(
          'business_account_id' => 'second-batch-waba',
          'app_secret' => second_secret
        )
      )
      payload = {
        object: 'whatsapp_business_account',
        entry: [
          { id: channel.provider_config['business_account_id'], changes: [{ field: 'account_update', value: {} }] },
          { id: 'second-batch-waba', changes: [{ field: 'account_update', value: {} }] }
        ]
      }.to_json
      allow(Webhooks::WhatsappEventsJob).to receive(:perform_later)

      post_whatsapp_webhook(
        '/webhooks/whatsapp',
        payload,
        signature: signature_for(payload, first_secret),
        env: {}
      )

      expect(response).to have_http_status(:unauthorized)
      expect(Webhooks::WhatsappEventsJob).not_to have_received(:perform_later)
    end

    it 'accepts a metadata-free multi-WABA batch signed by the configured application-wide secret' do
      global_secret = 'shared-application-secret'
      second_channel = create(
        :channel_whatsapp,
        account: create(:account, limits: { non_web_inboxes: ChatwootApp.max_limit }),
        provider: 'whatsapp_cloud',
        validate_provider_config: false,
        sync_templates: false
      )
      second_channel.update!(
        provider_config: second_channel.provider_config.merge(
          'business_account_id' => 'second-global-waba',
          'app_secret' => 'stale-waba-secret'
        )
      )
      payload = {
        object: 'whatsapp_business_account',
        entry: [
          { id: channel.provider_config['business_account_id'], changes: [{ field: 'account_update', value: {} }] },
          { id: 'second-global-waba', changes: [{ field: 'account_update', value: {} }] }
        ]
      }.to_json
      allow(Webhooks::WhatsappEventsJob).to receive(:perform_later)

      post_whatsapp_webhook(
        '/webhooks/whatsapp',
        payload,
        signature: signature_for(payload, global_secret),
        env: { WHATSAPP_APP_SECRET: global_secret }
      )

      expect(response).to have_http_status(:success)
      expect(Webhooks::WhatsappEventsJob).to have_received(:perform_later)
        .with(anything, hash_including(hmac_verified: true)).twice
    end

    it 'rejects an oversized WABA identity batch even when the global signature is valid' do
      global_secret = 'global-batch-secret'
      payload = {
        object: 'whatsapp_business_account',
        entry: Array.new(21) do |index|
          { id: "oversized-waba-#{index}", changes: [{ field: 'account_update', value: {} }] }
        end
      }.to_json
      allow(Webhooks::WhatsappEventsJob).to receive(:perform_later)

      post_whatsapp_webhook(
        '/webhooks/whatsapp',
        payload,
        signature: signature_for(payload, global_secret),
        env: { WHATSAPP_APP_SECRET: global_secret }
      )

      expect(response).to have_http_status(:unauthorized)
      expect(Webhooks::WhatsappEventsJob).not_to have_received(:perform_later)
    end

    it 'rejects a globally valid secret when the explicit channel does not match the callback WABA' do
      victim_secret = 'victim-channel-secret'
      untrusted_secret = 'different-waba-secret'
      untrusted_waba_id = 'different-waba-id'
      channel.update!(provider_config: channel.provider_config.merge('app_secret' => victim_secret))
      other_channel = create(
        :channel_whatsapp,
        account: create(:account, limits: { non_web_inboxes: ChatwootApp.max_limit }),
        provider: 'whatsapp_cloud',
        validate_provider_config: false,
        sync_templates: false
      )
      other_channel.update!(
        provider_config: other_channel.provider_config.merge(
          'business_account_id' => untrusted_waba_id,
          'app_secret' => untrusted_secret
        )
      )
      allow(Webhooks::WhatsappEventsJob).to receive(:perform_later)
      channel_body = {
        object: 'whatsapp_business_account',
        entry: [{
          id: untrusted_waba_id,
          changes: [{
            field: 'messages',
            value: {
              metadata: {
                display_phone_number: other_channel.phone_number.delete_prefix('+'),
                phone_number_id: other_channel.provider_config['phone_number_id']
              }
            }
          }]
        }]
      }.to_json

      post_whatsapp_webhook(
        "/webhooks/whatsapp/#{channel.phone_number}",
        channel_body,
        signature: signature_for(channel_body, untrusted_secret),
        env: { WHATSAPP_APP_SECRET: untrusted_secret }
      )

      expect(response).to have_http_status(:unauthorized)
      expect(Webhooks::WhatsappEventsJob).not_to have_received(:perform_later)
    end

    it 'does not forward a body-supplied phone number as a default callback route' do
      channel_secret = 'default-callback-channel-secret'
      waba_id = channel.provider_config['business_account_id']
      channel.update!(provider_config: channel.provider_config.merge('app_secret' => channel_secret))
      channel_body = {
        object: 'whatsapp_business_account',
        phone_number: '+199****99999',
        entry: [{
          id: waba_id,
          changes: [{
            field: 'messages',
            value: {
              metadata: {
                display_phone_number: channel.phone_number.delete_prefix('+'),
                phone_number_id: channel.provider_config['phone_number_id']
              }
            }
          }]
        }]
      }.to_json
      expect(Webhooks::WhatsappEventsJob).to receive(:perform_later) do |job_payload, verification_context|
        expect(job_payload).not_to have_key('phone_number')
        expect(verification_context).to eq(
          hmac_verified: true,
          channel_id: nil,
          channel_identity: {},
          waba_account_ids: { waba_id => channel.account_id },
          waba_scoped: true
        )
      end

      post_whatsapp_webhook(
        '/webhooks/whatsapp',
        channel_body,
        signature: signature_for(channel_body, channel_secret),
        env: {}
      )

      expect(response).to have_http_status(:success)
    end

    it 'preserves the explicit callback phone when the body supplies another number' do
      channel_secret = 'explicit-callback-channel-secret'
      channel.update!(provider_config: channel.provider_config.merge('app_secret' => channel_secret))
      channel_body = {
        object: 'whatsapp_business_account',
        phone_number: '+19999999999',
        entry: [{
          id: channel.provider_config['business_account_id'],
          changes: [{
            field: 'messages',
            value: {
              metadata: {
                display_phone_number: channel.phone_number.delete_prefix('+'),
                phone_number_id: channel.provider_config['phone_number_id']
              }
            }
          }]
        }]
      }.to_json
      expect(Webhooks::WhatsappEventsJob).to receive(:perform_later) do |job_payload, verification_context|
        expect(job_payload['phone_number']).to eq(channel.phone_number)
        expect(verification_context[:channel_id]).to eq(channel.id)
      end

      post_whatsapp_webhook(
        "/webhooks/whatsapp/#{channel.phone_number}",
        channel_body,
        signature: signature_for(channel_body, channel_secret),
        env: {}
      )

      expect(response).to have_http_status(:success)
    end

    it 'rejects an unsigned default callback even when a legacy channel resolves from the WABA id' do
      channel.update!(provider_config: channel.provider_config.except('app_secret', 'app_secret_key', 'api_secret', 'client_secret', 'source'))
      allow(Webhooks::WhatsappEventsJob).to receive(:perform_later)

      post_unsigned_whatsapp_webhook('/webhooks/whatsapp', default_account_update_body, env: {})

      expect(response).to have_http_status(:unauthorized)
      expect(Webhooks::WhatsappEventsJob).not_to have_received(:perform_later)
    end

    it 'calls the whatsapp events job with the params for a valid global app signature' do
      allow(Webhooks::WhatsappEventsJob).to receive(:perform_later)
      expect(Webhooks::WhatsappEventsJob).to receive(:perform_later).with(anything, hash_including(hmac_verified: true))

      post_whatsapp_webhook('/webhooks/whatsapp/15550000000', body)

      expect(response).to have_http_status(:success)
    end

    it 'accepts webhook payloads signed with the channel app secret' do
      channel_secret = '[REDACTED]'
      channel.update!(provider_config: channel.provider_config.merge('app_secret' => channel_secret))

      allow(Webhooks::WhatsappEventsJob).to receive(:perform_later)
      expect(Webhooks::WhatsappEventsJob).to receive(:perform_later)

      channel_body = {
        object: 'whatsapp_business_account',
        entry: [{
          changes: [{
            value: {
              metadata: {
                display_phone_number: channel.phone_number.delete_prefix('+'),
                phone_number_id: channel.provider_config['phone_number_id']
              }
            }
          }]
        }]
      }.to_json

      post_whatsapp_webhook(
        "/webhooks/whatsapp/#{channel.phone_number}",
        channel_body,
        signature: signature_for(channel_body, channel_secret),
        env: {}
      )

      expect(response).to have_http_status(:success)
    end

    it 'resolves a WABA-level coexistence webhook without metadata in the first change' do
      channel_secret = '[REDACTED]'
      waba_id = channel.provider_config['business_account_id']
      channel.update!(provider_config: channel.provider_config.merge('app_secret' => channel_secret))
      allow(Webhooks::WhatsappEventsJob).to receive(:perform_later)
      expect(Webhooks::WhatsappEventsJob).to receive(:perform_later)
      channel_body = {
        object: 'whatsapp_business_account',
        entry: [{ id: waba_id, changes: [{ field: 'history', value: { history: [] } }] }]
      }.to_json

      post_whatsapp_webhook(
        "/webhooks/whatsapp/#{channel.phone_number}",
        channel_body,
        signature: signature_for(channel_body, channel_secret),
        env: {}
      )

      expect(response).to have_http_status(:success)
    end

    it 'skips signature validation for 360dialog channels' do
      dialog_channel = create(:channel_whatsapp, provider: 'default', sync_templates: false, validate_provider_config: false)
      allow(Webhooks::WhatsappEventsJob).to receive(:perform_later)
      expect(Webhooks::WhatsappEventsJob).to receive(:perform_later).with(anything, hash_including(hmac_verified: false))

      post_unsigned_whatsapp_webhook("/webhooks/whatsapp/#{dialog_channel.phone_number}", body)

      expect(response).to have_http_status(:success)
    end

    it 'rejects legacy manual whatsapp cloud channels when no app secret is configured' do
      channel.update!(provider_config: channel.provider_config.except('app_secret', 'app_secret_key', 'api_secret', 'client_secret', 'source'))
      allow(Webhooks::WhatsappEventsJob).to receive(:perform_later)

      channel_body = {
        object: 'whatsapp_business_account',
        entry: [{
          changes: [{
            value: {
              metadata: {
                display_phone_number: channel.phone_number.delete_prefix('+'),
                phone_number_id: channel.provider_config['phone_number_id']
              }
            }
          }]
        }]
      }.to_json

      post_unsigned_whatsapp_webhook("/webhooks/whatsapp/#{channel.phone_number}", channel_body, env: {})

      expect(response).to have_http_status(:unauthorized)
      expect(Webhooks::WhatsappEventsJob).not_to have_received(:perform_later)
    end

    it 'rejects URL-resolved legacy manual whatsapp cloud channels when no app secret is configured' do
      channel.update!(provider_config: channel.provider_config.except('app_secret', 'app_secret_key', 'api_secret', 'client_secret', 'source'))
      allow(Webhooks::WhatsappEventsJob).to receive(:perform_later)

      post_unsigned_whatsapp_webhook("/webhooks/whatsapp/#{channel.phone_number}", body, env: {})

      expect(response).to have_http_status(:unauthorized)
      expect(Webhooks::WhatsappEventsJob).not_to have_received(:perform_later)
    end

    it 'rejects embedded-signup whatsapp cloud channels when no app secret is configured' do
      channel.update!(
        provider_config: channel.provider_config
                                .merge('source' => 'embedded_signup')
                                .except('app_secret', 'app_secret_key', 'api_secret', 'client_secret')
      )
      allow(Webhooks::WhatsappEventsJob).to receive(:perform_later)

      post_unsigned_whatsapp_webhook("/webhooks/whatsapp/#{channel.phone_number}", body, env: {})

      expect(response).to have_http_status(:unauthorized)
      expect(Webhooks::WhatsappEventsJob).not_to have_received(:perform_later)
    end

    it 'returns unauthorized when signature is missing and verification is required' do
      allow(Webhooks::WhatsappEventsJob).to receive(:perform_later)

      post_unsigned_whatsapp_webhook('/webhooks/whatsapp/15550000000', body)

      expect(response).to have_http_status(:unauthorized)
      expect(Webhooks::WhatsappEventsJob).not_to have_received(:perform_later)
    end

    it 'returns unauthorized when signature is invalid' do
      allow(Webhooks::WhatsappEventsJob).to receive(:perform_later)

      post_whatsapp_webhook('/webhooks/whatsapp/15550000000', body, signature: 'sha256=invalid-signature')

      expect(response).to have_http_status(:unauthorized)
      expect(Webhooks::WhatsappEventsJob).not_to have_received(:perform_later)
    end

    it 'returns unauthorized when signature uses an unsupported prefix' do
      allow(Webhooks::WhatsappEventsJob).to receive(:perform_later)

      post_whatsapp_webhook('/webhooks/whatsapp/15550000000', body, signature: 'sha1=invalid-signature')

      expect(response).to have_http_status(:unauthorized)
      expect(Webhooks::WhatsappEventsJob).not_to have_received(:perform_later)
    end

    context 'when phone number is in inactive list' do
      before do
        allow(GlobalConfig).to receive(:get_value).with('INACTIVE_WHATSAPP_NUMBERS').and_return('+15550000001,+15550000002')
      end

      it 'returns service unavailable for inactive phone number in URL params after signature verification' do
        allow(Rails.logger).to receive(:warn)
        expect(Rails.logger).to receive(:warn).with('Rejected webhook for inactive WhatsApp number: +15550000001')

        post_whatsapp_webhook('/webhooks/whatsapp/+15550000001', body)
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body['error']).to eq('Inactive WhatsApp number')
      end
    end

    context 'when INACTIVE_WHATSAPP_NUMBERS config is not set' do
      before do
        allow(GlobalConfig).to receive(:get_value).with('INACTIVE_WHATSAPP_NUMBERS').and_return(nil)
      end

      it 'processes the webhook normally with a valid signature' do
        allow(Webhooks::WhatsappEventsJob).to receive(:perform_later)
        expect(Webhooks::WhatsappEventsJob).to receive(:perform_later)

        post_whatsapp_webhook('/webhooks/whatsapp/+15550000001', body)
        expect(response).to have_http_status(:success)
      end
    end
  end
end
