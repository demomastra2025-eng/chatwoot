# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Whatsapp::EmbeddedSignupService do
  let(:account) { create(:account) }
  let(:physical_phone) { '+12025550100' }
  let(:access_token) { 'fresh-test-access-token' }
  let(:old_identity) do
    {
      'business_account_id' => '10001',
      'phone_number_id' => '20001',
      'business_id' => '30001',
      'source' => 'embedded_signup',
      'embedded_signup_flow' => 'coexistence'
    }
  end
  let(:coexistence_sync) do
    {
      'generation' => 'preserved-sync-generation',
      'state' => 'history_failed',
      'history_failed_at' => '2026-09-30T10:00:00Z',
      'history_failed_messages' => [{ 'id' => 'wamid.pending', 'error' => 'placeholder missing' }],
      'contacts_state' => 'manual_recovery_required',
      'contacts_pending_events_count' => 0
    }
  end
  let(:old_provider_config) do
    old_identity.merge(
      'api_key' => 'old-test-access-token',
      'webhook_verify_token' => 'stable-test-verify-token',
      'coexistence_sync' => coexistence_sync
    )
  end
  let(:channel) do
    created = create(
      :channel_whatsapp,
      account: account,
      provider: 'whatsapp_cloud',
      provider_config: old_provider_config,
      validate_provider_config: false,
      sync_templates: false
    )
    # The factory supplies safe defaults after creation; this fixture needs an
    # existing embedded-signup identity and a saved coexistence history state.
    created.update_columns( # rubocop:disable Rails/SkipsModelValidations
      phone_number: physical_phone,
      provider_config: old_provider_config
    )
    created
  end
  let(:inbox) { channel.inbox }
  let(:api_client) { instance_double(Whatsapp::FacebookApiClient) }
  let(:phone_info) do
    {
      phone_number_id: '20002',
      phone_number: physical_phone,
      is_on_biz_app: true,
      platform_type: 'CLOUD_API',
      verified: false
    }
  end
  let(:token_health) do
    {
      'status' => 'healthy',
      'waba_access' => true,
      'phone_number_access' => true
    }
  end
  let(:signup_service) do
    described_class.new(
      account: account,
      params: { code: 'fresh-test-code', signup_type: 'coexistence' },
      inbox_id: inbox.id
    )
  end

  before do
    allow(GlobalConfigService).to receive(:load).and_call_original
    allow(GlobalConfigService).to receive(:load)
      .with('WHATSAPP_APP_ID', '')
      .and_return('test-meta-app')
    allow(GlobalConfigService).to receive(:load)
      .with('WHATSAPP_REQUIRE_NON_EXPIRING_SYSTEM_USER_TOKEN', false)
      .and_return(false)
    allow(Whatsapp::FacebookApiClient).to receive(:new).with(access_token).and_return(api_client)
    allow(api_client).to receive(:debug_token).with(access_token).and_return(
      'data' => {
        'app_id' => 'test-meta-app',
        'is_valid' => true,
        'scopes' => %w[whatsapp_business_management whatsapp_business_messaging],
        'granular_scopes' => [
          { 'scope' => 'whatsapp_business_management', 'target_ids' => ['10002'] },
          { 'scope' => 'whatsapp_business_messaging', 'target_ids' => ['10002'] }
        ]
      }
    )
    allow(api_client).to receive(:fetch_phone_numbers).with(
      '10002',
      after: nil,
      fields: Whatsapp::PhoneInfoService::PHONE_NUMBER_FIELDS
    ).and_return(
      'data' => [
        {
          'id' => '20002',
          'display_phone_number' => physical_phone,
          'verified_name' => 'Retained business',
          'is_on_biz_app' => true,
          'platform_type' => 'CLOUD_API'
        }
      ]
    )
    allow(api_client).to receive(:fetch_waba_info).with(
      '10002',
      fields: ['owner_business_info']
    ).and_return('owner_business_info' => { 'id' => '30001' })
    allow(api_client).to receive(:validate_waba_message_templates_access).with('10002').and_return(true)

    token_exchange = instance_double(Whatsapp::TokenExchangeService, perform: access_token)
    allow(Whatsapp::TokenExchangeService).to receive(:new)
      .with('fresh-test-code')
      .and_return(token_exchange)
    phone_service = instance_double(Whatsapp::PhoneInfoService, perform: phone_info)
    allow(Whatsapp::PhoneInfoService).to receive(:new)
      .with('10002', '20002', access_token, coexistence: true)
      .and_return(phone_service)
    validation_service = instance_double(Whatsapp::TokenValidationService, perform: token_health)
    allow(Whatsapp::TokenValidationService).to receive(:new).with(
      access_token,
      '10002',
      phone_number_id: '20002',
      require_non_expiring_system_user: false
    ).and_return(validation_service)
  end

  # This is deliberately one cross-service regression: the job, real resolver,
  # real reauthorization service, and callback finalizer must agree on identity.
  # rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations
  it 'recovers the same coexistence inbox after a failed delete without losing history or sync state' do
    inbox.update!(name: 'Retained WhatsApp inbox')
    member = create(:inbox_member, inbox: inbox, user: create(:user, account: account))
    conversation = create(:conversation, account: account, inbox: inbox)
    message = create(
      :message,
      account: account,
      inbox: inbox,
      conversation: conversation,
      content: 'Preserved conversation history'
    )
    preserved_sync = channel.reload.provider_config.fetch('coexistence_sync').deep_dup

    deletion_attempt_id = SecureRandom.uuid
    inbox.mark_pending_deletion!(attempt_id: deletion_attempt_id)
    teardown_service = instance_double(Whatsapp::WebhookTeardownService)
    allow(Whatsapp::WebhookTeardownService).to receive(:new).with(channel).and_return(teardown_service)
    allow(teardown_service).to receive(:perform).and_raise(
      Whatsapp::WebhookTeardownService::WebhookTeardownError,
      'simulated remote unsubscribe failure'
    )

    expect do
      DeleteObjectJob.perform_now(inbox, nil, nil, deletion_attempt_id)
    end.not_to raise_error

    expect(inbox.reload).to have_attributes(deleting_at: nil, deletion_attempt_id: nil)
    expect(channel.reload.inbox_deletion_recovery).to include(
      'status' => 'failed',
      'attempt_id' => deletion_attempt_id,
      'remote_outcome' => 'unknown'
    )

    callback_service = instance_double(Whatsapp::WebhookSetupService, register_callback: true)
    allow(Whatsapp::WebhookSetupService).to receive(:new)
      .with(instance_of(Channel::Whatsapp))
      .and_return(callback_service)

    recovered_channel = nil
    expect do
      recovered_channel = signup_service.perform
    end.not_to have_enqueued_job(Whatsapp::CoexistenceSyncJob)

    expect(recovered_channel).to eq(channel)
    updated_config = channel.reload.provider_config
    expect(updated_config).to include(
      'business_account_id' => '10002',
      'phone_number_id' => '20002',
      'business_id' => '30001'
    )
    expect(updated_config.fetch('coexistence_sync')).to eq(preserved_sync)
    expect(inbox.reload.name).to eq('Retained WhatsApp inbox')
    expect(inbox.inbox_members.pluck(:id)).to contain_exactly(member.id)
    expect(message.reload).to have_attributes(
      conversation_id: conversation.id,
      inbox_id: inbox.id,
      content: 'Preserved conversation history'
    )
    expect(inbox.deletion_recovery_failed?).to be(false)
    expect(updated_config.fetch('inbox_deletion_recovery')).to include(
      'status' => 'resolved',
      'attempt_id' => deletion_attempt_id,
      'remote_outcome' => 'subscription_restored'
    )
    expect(updated_config.dig('inbox_deletion_recovery', 'last_failure')).to include(
      'error_code' => 'remote_teardown_failed',
      'remote_outcome' => 'unknown'
    )
    expect(callback_service).to have_received(:register_callback).once
    expect(teardown_service).to have_received(:perform).once

    expect do
      DeleteObjectJob.perform_now(inbox)
      DeleteObjectJob.perform_now(inbox, nil, nil, deletion_attempt_id)
    end.not_to(change do
      [
        Inbox.exists?(inbox.id),
        Channel::Whatsapp.exists?(channel.id),
        Conversation.exists?(conversation.id),
        Message.exists?(message.id)
      ]
    end)
    expect(inbox.reload).not_to be_deleting
    expect(teardown_service).to have_received(:perform).once
  end
  # rubocop:enable RSpec/ExampleLength, RSpec/MultipleExpectations
end
