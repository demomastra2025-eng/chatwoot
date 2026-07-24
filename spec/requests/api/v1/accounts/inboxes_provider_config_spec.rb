require 'rails_helper'

RSpec.describe 'WhatsApp inbox provider config', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:channel) do
    create(
      :channel_whatsapp,
      account: account,
      provider: 'whatsapp_cloud',
      sync_templates: false,
      validate_provider_config: false
    )
  end

  let(:sensitive_provider_config) do
    {
      'source' => 'embedded_signup',
      'embedded_signup_flow' => 'coexistence',
      'business_account_id' => 'waba-123',
      'phone_number_id' => 'phone-123',
      'app_secret' => 'hidden-app-secret',
      'app_secret_key' => 'hidden-app-secret-key',
      'client_secret' => 'hidden-client-secret',
      'api_secret' => 'hidden-api-secret',
      'api_key' => 'hidden-provider-key',
      'webhook_verify_token' => 'hidden-setup-token',
      'verification_pin' => '123456',
      'future_secret' => 'hidden-by-default',
      'coexistence_sync' => {
        'state' => 'history_failed',
        'history_progress' => 75,
        'future_secret' => 'nested-hidden-by-default',
        'history_failed_messages' => [{
          'id' => 'wamid.failed',
          'kind' => 'history_thread',
          'error' => 'safe summary',
          'message' => { 'text' => { 'body' => 'private customer message' }, 'access_token' => 'nested-token' },
          'metadata' => { 'api_key' => 'nested-key' },
          'thread_id' => 'private-thread'
        }]
      },
      'webhook_callback_recovery' => {
        'state' => 'manual_recovery_required',
        'waba_id' => 'waba-123',
        'last_error' => 'Bearer hidden-provider-key',
        'generation' => 'private-generation',
        'callback_url' => 'https://private.example/callback'
      },
      'meta_webhook_lifecycle' => {
        'counters' => { 'security' => 2 },
        'last_event_at' => '2026-07-18T20:00:00Z',
        'recent_fingerprints' => ['private-fingerprint'],
        'latest' => { 'security' => { 'payload' => 'private-payload' } }
      }
    }
  end

  it 'returns only allowlisted non-secret WhatsApp provider fields to administrators', :aggregate_failures do
    channel.update!(provider_config: channel.provider_config.merge(sensitive_provider_config))

    get "/api/v1/accounts/#{account.id}/inboxes", headers: admin.create_new_auth_token, as: :json

    payload = JSON.parse(response.body, symbolize_names: true)[:payload]
    provider_config = payload.find { |item| item[:id] == channel.inbox.id }[:provider_config]
    expect(provider_config).to include(
      source: 'embedded_signup',
      embedded_signup_flow: 'coexistence',
      business_account_id: 'waba-123',
      phone_number_id: 'phone-123'
    )
    expect(provider_config.keys).to all(be_in(Whatsapp::ProviderConfigPresenter::PUBLIC_PROVIDER_CONFIG_KEYS.map(&:to_sym)))
    expect(provider_config.keys).not_to include(
      :api_key, :webhook_verify_token, :verification_pin, :future_secret,
      *MetaTokenVerifyConcern::CHANNEL_APP_SECRET_KEYS.map(&:to_sym)
    )
    expect(provider_config[:coexistence_sync]).to include(state: 'history_failed', history_progress: 75)
    expect(provider_config.dig(:coexistence_sync, :history_failed_messages)).to eq(
      [{ id: 'wamid.failed', kind: 'history_thread', error: 'safe summary' }]
    )
    expect(provider_config[:webhook_callback_recovery]).to include(
      state: 'manual_recovery_required', waba_id: 'waba-123', last_error: 'Bearer [FILTERED]'
    )
    expect(provider_config[:meta_webhook_lifecycle]).to eq(
      counters: { security: 2 }, last_event_at: '2026-07-18T20:00:00Z'
    )
    expect(provider_config[:coexistence_sync].to_json).not_to include(
      'future_secret', 'private customer message', 'nested-token', 'nested-key', 'thread_id', 'metadata'
    )
    expect(provider_config.to_json).not_to include(
      'hidden-provider-key', 'private-generation', 'private.example', 'private-fingerprint', 'private-payload'
    )
  end

  it 'returns the registered channel-bound webhook URL for a manual Cloud inbox without exposing its token' do
    channel.update!(
      provider_config: channel.provider_config.merge(
        'source' => 'manual',
        'webhook_verify_token' => 'manual-channel-token'
      )
    )

    with_modified_env('FRONTEND_URL' => 'https://app.example.test') do
      get "/api/v1/accounts/#{account.id}/inboxes", headers: admin.create_new_auth_token, as: :json
    end

    inbox_payload = response.parsed_body['payload'].find { |item| item['id'] == channel.inbox.id }
    expect(inbox_payload['callback_webhook_url'])
      .to eq("https://app.example.test/webhooks/whatsapp?channel_id=#{channel.id}")
    expect(inbox_payload.fetch('provider_config')).not_to have_key('webhook_verify_token')
    expect(response.body).not_to include('manual-channel-token')
  end

  it 'holds the incoming WABA lock around generic Cloud inbox creation' do
    token_validation = instance_double(Whatsapp::TokenValidationService, perform: {})
    provider_service = instance_double(Whatsapp::Providers::WhatsappCloudService, validate_provider_config?: true, sync_templates: true)
    setup_service = instance_double(Whatsapp::WebhookSetupService, perform: true)
    allow(Whatsapp::TokenValidationService).to receive(:new).and_return(token_validation)
    allow(Whatsapp::Providers::WhatsappCloudService).to receive(:new).and_return(provider_service)
    allow(Whatsapp::WebhookSetupService).to receive(:new).and_return(setup_service)
    allow(Whatsapp::WabaLock).to receive(:with_locks).and_yield
    auth_headers = admin.create_new_auth_token

    post "/api/v1/accounts/#{account.id}/inboxes",
         headers: auth_headers,
         params: {
           name: 'Locked Cloud Inbox',
           channel: {
             type: 'whatsapp',
             provider: 'whatsapp_cloud',
             phone_number: "+1555#{SecureRandom.random_number(10**8).to_s.rjust(8, '0')}",
             provider_config: {
               api_key: 'manual-cloud-token',
               business_account_id: 'waba-create',
               phone_number_id: 'phone-create',
               webhook_verify_token: 'one-time-setup-token'
             }
           }
         },
         as: :json

    expect(response).to have_http_status(:success)
    expect(Whatsapp::WabaLock).to have_received(:with_locks).with(['waba-create'])
    expect(response.parsed_body.dig('provider_config', 'webhook_verify_token')).to eq('one-time-setup-token')

    created_inbox_id = response.parsed_body['id']
    get "/api/v1/accounts/#{account.id}/inboxes", headers: auth_headers, as: :json

    expect(response).to have_http_status(:success)
    stored_inbox = response.parsed_body.fetch('payload').find { |item| item['id'] == created_inbox_id }
    expect(stored_inbox.fetch('provider_config')).not_to have_key('webhook_verify_token')
  end

  it 'rejects generic Cloud identity updates while holding the old and incoming WABA locks' do
    channel.update!(provider_config: channel.provider_config.merge('business_account_id' => 'waba-old'))
    token_validation = instance_double(Whatsapp::TokenValidationService, perform: {})
    provider_service = instance_double(Whatsapp::Providers::WhatsappCloudService, validate_provider_config?: true)
    allow(Whatsapp::TokenValidationService).to receive(:new).and_return(token_validation)
    allow(Whatsapp::Providers::WhatsappCloudService).to receive(:new).and_return(provider_service)
    allow(Whatsapp::WabaLock).to receive(:with_locks).and_yield

    patch "/api/v1/accounts/#{account.id}/inboxes/#{channel.inbox.id}",
          headers: admin.create_new_auth_token,
          params: {
            channel: {
              provider_config: { business_account_id: 'waba-new' }
            }
          },
          as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(Whatsapp::WabaLock).to have_received(:with_locks).with(%w[waba-old waba-new])
    expect(channel.reload.provider_config['business_account_id']).to eq('waba-old')
  end

  it 'rejects a generic Cloud provider downgrade before changing the webhook security boundary' do
    expect(Whatsapp::TokenValidationService).not_to receive(:new)

    patch "/api/v1/accounts/#{account.id}/inboxes/#{channel.inbox.id}",
          headers: admin.create_new_auth_token,
          params: { channel: { provider: 'default' } },
          as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(channel.reload.provider).to eq('whatsapp_cloud')
  end

  it 'reloads and retries the WABA lock set when identity changes before lock acquisition' do
    channel.update!(provider_config: channel.provider_config.merge('business_account_id' => 'waba-old'))
    token_validation = instance_double(Whatsapp::TokenValidationService, perform: {})
    provider_service = instance_double(Whatsapp::Providers::WhatsappCloudService, validate_provider_config?: true)
    allow(Whatsapp::TokenValidationService).to receive(:new).and_return(token_validation)
    allow(Whatsapp::Providers::WhatsappCloudService).to receive(:new).and_return(provider_service)
    lock_calls = []
    identity_transitioned = false
    allow(Whatsapp::WabaLock).to receive(:with_locks) do |waba_ids, &block|
      lock_calls << waba_ids
      unless identity_transitioned
        identity_transitioned = true
        fresh_channel = Channel::Whatsapp.find(channel.id)
        fresh_channel.update!(
          provider_config: fresh_channel.provider_config.merge('business_account_id' => 'waba-new')
        )
      end
      block.call
    end

    patch "/api/v1/accounts/#{account.id}/inboxes/#{channel.inbox.id}",
          headers: admin.create_new_auth_token,
          params: { channel: { provider_config: { api_key: 'rotated-api-key' } } },
          as: :json

    expect(response).to have_http_status(:success)
    expect(lock_calls).to eq([['waba-old'], ['waba-new']])
    expect(channel.reload.provider_config).to include(
      'business_account_id' => 'waba-new',
      'api_key' => 'rotated-api-key'
    )
  end

  it 'returns conflict instead of 500 when a WABA operation already holds the lock' do
    allow(Whatsapp::WabaLock).to receive(:with_locks)
      .and_raise(Whatsapp::WabaLock::LockAcquisitionError, 'already locked')

    patch "/api/v1/accounts/#{account.id}/inboxes/#{channel.inbox.id}",
          headers: admin.create_new_auth_token,
          params: { name: 'Renamed while locked' },
          as: :json

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body['error']).to eq('Another WhatsApp Business Account operation is already in progress')
  end

  it 'rejects sequential generic creation of a second coexistence channel for one WABA' do
    sibling = create(:channel_whatsapp, account: account, provider: 'whatsapp_cloud',
                                        validate_provider_config: false, sync_templates: false)
    sibling.update!(
      provider_config: sibling.provider_config.merge(
        'business_account_id' => 'waba-conflict',
        'embedded_signup_flow' => 'coexistence'
      )
    )
    token_validation = instance_double(Whatsapp::TokenValidationService, perform: {})
    provider_service = instance_double(Whatsapp::Providers::WhatsappCloudService, validate_provider_config?: true, sync_templates: true)
    allow(Whatsapp::TokenValidationService).to receive(:new).and_return(token_validation)
    allow(Whatsapp::Providers::WhatsappCloudService).to receive(:new).and_return(provider_service)
    allow(Whatsapp::WabaLock).to receive(:with_locks).and_yield

    expect do
      post "/api/v1/accounts/#{account.id}/inboxes",
           headers: admin.create_new_auth_token,
           params: {
             name: 'Conflicting Cloud Inbox',
             channel: {
               type: 'whatsapp',
               provider: 'whatsapp_cloud',
               phone_number: "+1555#{SecureRandom.random_number(10**8).to_s.rjust(8, '0')}",
               provider_config: {
                 api_key: 'manual-cloud-token',
                 business_account_id: 'waba-conflict',
                 phone_number_id: 'phone-conflict',
                 embedded_signup_flow: 'coexistence'
               }
             }
           },
           as: :json
    end.not_to change(Channel::Whatsapp, :count)

    expect(response).to have_http_status(:unprocessable_content)
    expect(Whatsapp::WabaLock).to have_received(:with_locks).with(['waba-conflict'])
  end

  it 'rejects moving a coexistence channel onto an occupied coexistence WABA' do
    channel.update!(
      provider_config: channel.provider_config.merge(
        'business_account_id' => 'waba-source',
        'embedded_signup_flow' => 'coexistence'
      )
    )
    sibling = create(:channel_whatsapp, account: account, provider: 'whatsapp_cloud',
                                        validate_provider_config: false, sync_templates: false)
    sibling.update!(
      provider_config: sibling.provider_config.merge(
        'business_account_id' => 'waba-destination',
        'embedded_signup_flow' => 'coexistence'
      )
    )
    token_validation = instance_double(Whatsapp::TokenValidationService, perform: {})
    provider_service = instance_double(Whatsapp::Providers::WhatsappCloudService, validate_provider_config?: true)
    allow(Whatsapp::TokenValidationService).to receive(:new).and_return(token_validation)
    allow(Whatsapp::Providers::WhatsappCloudService).to receive(:new).and_return(provider_service)
    allow(Whatsapp::WabaLock).to receive(:with_locks).and_yield

    patch "/api/v1/accounts/#{account.id}/inboxes/#{channel.inbox.id}",
          headers: admin.create_new_auth_token,
          params: {
            channel: {
              provider_config: {
                business_account_id: 'waba-destination',
                embedded_signup_flow: 'coexistence'
              }
            }
          },
          as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(channel.reload.provider_config['business_account_id']).to eq('waba-source')
    expect(Whatsapp::WabaLock).to have_received(:with_locks).with(%w[waba-source waba-destination])
  end
end
