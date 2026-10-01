require 'rails_helper'

RSpec.describe Whatsapp::ReauthorizationService do
  let(:account) { create(:account) }
  let(:channel) do
    create(
      :channel_whatsapp,
      account: account,
      provider: 'whatsapp_cloud',
      provider_config: existing_provider_config,
      validate_provider_config: false,
      sync_templates: false
    ).tap { |record| record.update!(provider_config: existing_provider_config) }
  end
  let(:inbox) { channel.inbox }
  let(:provider_identity) do
    {
      'phone_number_id' => 'phone-1',
      'business_account_id' => 'waba-1',
      'business_id' => 'business-1'
    }
  end
  let(:existing_provider_config) { provider_identity.merge('source' => 'embedded_signup') }
  let(:facebook_api_client) { instance_double(Whatsapp::FacebookApiClient) }
  let(:phone_info) do
    {
      phone_number: channel.phone_number,
      business_name: 'Reauthorized WhatsApp',
      calling_capable: true,
      calling_capabilities: ['CALLING']
    }
  end

  before do
    setup_service = instance_double(Whatsapp::WebhookSetupService)
    allow(Whatsapp::WebhookSetupService).to receive(:new).and_return(setup_service)
    allow(setup_service).to receive(:perform)
    allow(Whatsapp::FacebookApiClient).to receive(:new).with('new-token').and_return(facebook_api_client)
    allow(facebook_api_client).to receive(:validate_waba_message_templates_access).and_return(true)
  end

  it 'enables WhatsApp Calling by default when capability is present and no manual toggle exists' do
    described_class.new(
      account: account,
      inbox_id: inbox.id,
      phone_number_id: 'phone-1',
      business_id: 'business-1',
      waba_id: 'waba-1'
    ).perform('new-token', phone_info)

    expect(channel.reload.provider_config).to include(
      'calling_capable' => true,
      'calling_enabled' => true,
      'calling_capabilities' => ['CALLING']
    )
  end

  it 'does not persist provider or durable authorization errors when candidate preflight fails' do
    previous_config = channel.provider_config.deep_dup
    previous_error_count = channel.authorization_error_count
    previous_reauthorization_claim = Redis::Alfred.get(channel.send(:reauthorization_required_key))
    allow(facebook_api_client).to receive(:validate_waba_message_templates_access).and_return(false)

    service = described_class.new(
      account: account,
      inbox_id: inbox.id,
      phone_number_id: 'phone-1',
      business_id: 'business-1',
      waba_id: 'waba-1'
    )

    expect { service.perform('new-token', phone_info) }.to raise_error(ActiveRecord::RecordInvalid)
    expect(channel.reload.provider_config).to eq(previous_config)
    expect(channel.authorization_error_count).to eq(previous_error_count)
    expect(Redis::Alfred.get(channel.send(:reauthorization_required_key))).to eq(previous_reauthorization_claim)
  end

  it 'validates provider credentials before acquiring WABA and database row locks' do
    waba_lock_acquired = false
    allow(Whatsapp::WabaLock).to receive(:with_locks) do |_waba_ids, &block|
      waba_lock_acquired = true
      block.call
    end
    allow(facebook_api_client).to receive(:validate_waba_message_templates_access) do |_waba_id|
      expect(waba_lock_acquired).to be(false)
      true
    end

    described_class.new(
      account: account,
      inbox_id: inbox.id,
      phone_number_id: 'phone-1',
      business_id: 'business-1',
      waba_id: 'waba-1'
    ).perform('new-token', phone_info)

    expect(waba_lock_acquired).to be(true)
  end

  it 'rejects WABA identity changes before acquiring a provider lifecycle lock' do
    channel.update!(provider_config: channel.provider_config.merge('business_account_id' => 'waba-old'))
    allow(Whatsapp::WabaLock).to receive(:with_locks)

    service = described_class.new(
      account: account,
      inbox_id: inbox.id,
      phone_number_id: 'phone-1',
      business_id: 'business-1',
      waba_id: 'waba-new'
    )

    expect { service.perform('new-token', phone_info) }
      .to raise_error(Whatsapp::ReauthorizationService::IdentityMismatchError)
    expect(channel.reload.provider_config['business_account_id']).to eq('waba-old')
    expect(Whatsapp::WabaLock).not_to have_received(:with_locks)
  end

  it 'rejects an identity change that occurs after validation but before the WABA locks are acquired' do
    allow(Whatsapp::WabaLock).to receive(:with_locks) do |_waba_ids, &block|
      channel.update!(provider_config: channel.provider_config.merge('phone_number_id' => 'phone-concurrent'))
      block.call
    end
    service = described_class.new(
      account: account,
      inbox_id: inbox.id,
      phone_number_id: 'phone-1',
      business_id: 'business-1',
      waba_id: 'waba-1'
    )

    expect { service.perform('new-token', phone_info) }
      .to raise_error(Whatsapp::ReauthorizationService::IdentityMismatchError)
    expect(channel.reload.provider_config).to include('phone_number_id' => 'phone-concurrent')
    expect(channel.provider_config['api_key']).not_to eq('new-token')
  end

  it 'keeps reauthorization and callback recovery anchors committed when remote setup fails after credentials are saved' do
    channel.update!(provider_config: channel.provider_config.merge('reauthorization_required' => true))
    service = described_class.new(
      account: account,
      inbox_id: inbox.id,
      phone_number_id: 'phone-1',
      business_id: 'business-1',
      waba_id: 'waba-1'
    )
    recovery_error = Whatsapp::FacebookApiClient::WebhookCallbackOutcomeUnknownError.new('outcome unknown')

    expect do
      service.perform('new-token', phone_info) do |current_channel|
        config = current_channel.reload.provider_config.deep_dup
        config['webhook_callback_recovery'] = {
          'state' => 'outcome_unknown',
          'generation' => 'recovery-generation',
          'waba_id' => 'waba-1'
        }
        current_channel.persist_provider_config_state!(config)
        raise recovery_error
      end
    end.to raise_error(recovery_error)

    expect(channel.reload.provider_config).to include(
      'api_key' => 'new-token',
      'reauthorization_required' => true,
      'webhook_callback_recovery' => include(
        'state' => 'outcome_unknown',
        'generation' => 'recovery-generation',
        'waba_id' => 'waba-1'
      )
    )
  end

  it 'rejects coexistence reauthorization onto a different WABA before checking occupancy' do
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
    allow(Whatsapp::WabaLock).to receive(:with_locks).and_yield
    stub_request(:get, 'https://graph.facebook.com/v25.0/waba-destination/message_templates')
      .to_return(status: 200, body: { data: [] }.to_json, headers: { 'Content-Type' => 'application/json' })

    service = described_class.new(
      account: account,
      inbox_id: inbox.id,
      phone_number_id: 'phone-1',
      business_id: 'business-1',
      waba_id: 'waba-destination',
      signup_type: 'coexistence'
    )

    expect { service.perform('new-token', phone_info) }
      .to raise_error(Whatsapp::ReauthorizationService::IdentityMismatchError)
    expect(channel.reload.provider_config['business_account_id']).to eq('waba-source')
    expect(Whatsapp::WabaLock).not_to have_received(:with_locks)
  end

  context 'when recovering a changed identity for the retained coexistence phone' do
    let(:existing_provider_config) do
      provider_identity.merge(
        'source' => 'embedded_signup',
        'embedded_signup_flow' => 'coexistence',
        'coexistence_sync' => {
          'state' => 'failed',
          'generation' => 'old-generation',
          'failure_code' => 'history_failed',
          'history_request_id' => 'preserve-this'
        },
        'authorization_status' => 'reauthorization_required',
        'authorization_error' => { 'code' => 190, 'message' => 'Retain until callback succeeds' },
        'inbox_deletion_recovery' => {
          'attempt_id' => 'deletion-attempt',
          'status' => 'failed',
          'error_code' => 'remote_outcome_unknown'
        }
      )
    end
    let(:phone_info) do
      {
        phone_number_id: 'phone-new',
        phone_number: channel.phone_number,
        is_on_biz_app: true,
        platform_type: 'CLOUD_API',
        calling_capable: false
      }
    end
    let(:identity_resolution) do
      Whatsapp::ReauthorizationIdentityResolver::Resolution.new(
        account_id: account.id,
        inbox_id: inbox.id,
        channel_id: channel.id,
        old_identity: channel.provider_config.to_h.slice(*Whatsapp::ReauthorizationIdentityResolver::Resolution::IDENTITY_KEYS),
        target_identity: {
          'business_account_id' => 'waba-new',
          'phone_number_id' => 'phone-new',
          'business_id' => 'business-1',
          'source' => 'embedded_signup',
          'embedded_signup_flow' => 'coexistence'
        },
        phone_number: phone_info[:phone_number],
        physical_phone: Whatsapp::ReauthorizationIdentityResolver.normalize_phone(phone_info[:phone_number]),
        owner_business_id: 'business-1',
        access_token: 'new-token'
      )
    end

    it 'updates only the proven provider identity and preserves inbox and history state', :aggregate_failures do
      inbox.update!(name: 'Keep this inbox name')
      original_name = inbox.name
      conversation = create(:conversation, account: account, inbox: inbox)
      message = create(:message, account: account, inbox: inbox, conversation: conversation, content: 'Keep this message')
      original_sync = channel.provider_config['coexistence_sync'].deep_dup

      result = described_class.new(
        account: account,
        inbox_id: inbox.id,
        phone_number_id: 'phone-new',
        business_id: 'business-1',
        waba_id: 'waba-new',
        signup_type: 'coexistence',
        identity_resolution: identity_resolution
      ).perform('new-token', phone_info)

      expect(result.id).to eq(channel.id)
      expect(channel.reload.provider_config).to include(
        'api_key' => 'new-token',
        'business_account_id' => 'waba-new',
        'phone_number_id' => 'phone-new',
        'business_id' => 'business-1'
      )
      expect(channel.provider_config['coexistence_sync']).to eq(original_sync)
      expect(channel.provider_config).to include(
        'authorization_status' => 'reauthorization_required',
        'authorization_error' => include('code' => 190),
        'inbox_deletion_recovery' => include(
          'attempt_id' => 'deletion-attempt',
          'status' => 'failed',
          'error_code' => 'remote_outcome_unknown'
        )
      )
      expect(inbox.reload.name).to eq(original_name)
      expect(inbox.channel).to eq(channel)
      expect(conversation.reload.inbox).to eq(inbox)
      expect(message.reload.conversation).to eq(conversation)
    end

    it 'rejects a changed identity if another account owns the target WABA, including a deleting inbox' do
      other_account = create(:account)
      other_channel = create(
        :channel_whatsapp,
        account: other_account,
        provider: 'whatsapp_cloud',
        validate_provider_config: false,
        sync_templates: false
      )
      other_channel.update!(
        provider_config: {
          'business_account_id' => 'waba-new',
          'phone_number_id' => 'another-phone',
          'source' => 'embedded_signup',
          'embedded_signup_flow' => 'standard'
        }
      )
      other_channel.inbox.update!(deleting_at: Time.current)

      service = described_class.new(
        account: account,
        inbox_id: inbox.id,
        phone_number_id: 'phone-new',
        business_id: 'business-1',
        waba_id: 'waba-new',
        signup_type: 'coexistence',
        identity_resolution: identity_resolution
      )

      expect { service.perform('new-token', phone_info) }
        .to raise_error(Whatsapp::ReauthorizationService::IdentityMismatchError)
      expect(channel.reload.provider_config['business_account_id']).to eq('waba-1')
    end

    it 'rejects a target phone id already owned by another local channel' do
      sibling = create(
        :channel_whatsapp,
        account: account,
        provider: 'whatsapp_cloud',
        validate_provider_config: false,
        sync_templates: false
      )
      sibling.update!(
        provider_config: {
          'business_account_id' => 'another-waba',
          'phone_number_id' => 'phone-new',
          'source' => 'embedded_signup',
          'embedded_signup_flow' => 'standard'
        }
      )
      service = described_class.new(
        account: account,
        inbox_id: inbox.id,
        phone_number_id: 'phone-new',
        business_id: 'business-1',
        waba_id: 'waba-new',
        signup_type: 'coexistence',
        identity_resolution: identity_resolution
      )

      expect { service.perform('new-token', phone_info) }
        .to raise_error(Whatsapp::ReauthorizationService::IdentityMismatchError)
      expect(channel.reload.provider_config['business_account_id']).to eq('waba-1')
    end

    it 'rejects a stale proof after the persisted identity changes' do
      allow(Whatsapp::WabaLock).to receive(:with_locks) do |_ids, &block|
        channel.update!(provider_config: channel.provider_config.merge('phone_number_id' => 'phone-concurrent'))
        block.call
      end
      service = described_class.new(
        account: account,
        inbox_id: inbox.id,
        phone_number_id: 'phone-new',
        business_id: 'business-1',
        waba_id: 'waba-new',
        signup_type: 'coexistence',
        identity_resolution: identity_resolution
      )

      expect { service.perform('new-token', phone_info) }
        .to raise_error(Whatsapp::ReauthorizationService::IdentityMismatchError)
      expect(channel.reload.provider_config['api_key']).not_to eq('new-token')
    end

    it 'refuses to update an inbox already marked for deletion' do
      inbox.update!(deleting_at: Time.current)
      service = described_class.new(
        account: account,
        inbox_id: inbox.id,
        phone_number_id: 'phone-new',
        business_id: 'business-1',
        waba_id: 'waba-new',
        signup_type: 'coexistence',
        identity_resolution: identity_resolution
      )

      expect { service.perform('new-token', phone_info) }
        .to raise_error(ActiveRecord::RecordNotFound)
      expect(channel.reload.provider_config['business_account_id']).to eq('waba-1')
    end
  end

  context 'when calling was manually disabled' do
    let(:existing_provider_config) do
      provider_identity.merge('source' => 'embedded_signup', 'calling_enabled' => false)
    end

    it 'preserves the explicit disable while refreshing capability metadata' do
      described_class.new(
        account: account,
        inbox_id: inbox.id,
        phone_number_id: 'phone-1',
        business_id: 'business-1',
        waba_id: 'waba-1'
      ).perform('new-token', phone_info)

      expect(channel.reload.provider_config).to include(
        'calling_capable' => true,
        'calling_enabled' => false,
        'calling_capabilities' => ['CALLING']
      )
    end
  end

  context 'when a coexistence sync request was already accepted without a request id' do
    let(:existing_provider_config) do
      provider_identity.merge(
        'source' => 'embedded_signup',
        'embedded_signup_flow' => 'coexistence',
        'coexistence_sync' => {
          'state' => 'requested',
          'history_request_state' => 'requested',
          'smb_app_state_sync_request_state' => 'requested'
        }
      )
    end

    it 'preserves the one-time sync state during reauthorization' do
      described_class.new(
        account: account,
        inbox_id: inbox.id,
        phone_number_id: 'phone-1',
        business_id: nil,
        waba_id: 'waba-1',
        signup_type: 'coexistence'
      ).perform('new-token', phone_info)

      sync = channel.reload.provider_config['coexistence_sync']
      expect(sync).to include(existing_provider_config['coexistence_sync'])
      expect(sync['generation']).to be_present
    end
  end

  context 'when coexistence sync requires manual recovery' do
    let(:existing_provider_config) do
      provider_identity.merge(
        'source' => 'embedded_signup',
        'embedded_signup_flow' => 'coexistence',
        'coexistence_sync' => {
          'state' => 'manual_recovery_required',
          'history_request_state' => 'manual_recovery_required',
          'history_request_id' => 'stale-request'
        }
      )
    end

    it 'opens a fresh sync window and removes stale one-time request claims on explicit reauthorization' do
      described_class.new(
        account: account,
        inbox_id: inbox.id,
        phone_number_id: 'phone-1',
        business_id: nil,
        waba_id: 'waba-1',
        signup_type: 'coexistence'
      ).perform('new-token', phone_info)

      sync = channel.reload.provider_config['coexistence_sync']
      expect(sync).to include('state' => 'pending')
      expect(sync['deadline_at']).to be_present
      expect(sync).not_to include('history_request_state', 'history_request_id')
    end
  end

  context 'when the existing channel is flagged for reauthorization' do
    let(:existing_provider_config) do
      provider_identity.merge(
        'source' => 'embedded_signup',
        'authorization_status' => 'reauthorization_required',
        'authorization_error' => {
          'code' => 190,
          'message' => 'Expired token',
          'recorded_at' => 1.hour.ago.iso8601
        }
      )
    end

    it 'refreshes credentials on the same inbox/channel and preserves conversation data', :aggregate_failures do
      conversation = create(:conversation, account: account, inbox: inbox)
      message = create(:message, account: account, inbox: inbox, conversation: conversation, content: 'Preserve me')

      channel.prompt_reauthorization!

      result = described_class.new(
        account: account,
        inbox_id: inbox.id,
        phone_number_id: 'phone-1',
        business_id: 'business-1',
        waba_id: 'waba-1'
      ).perform('new-token', phone_info)

      expect(result.id).to eq(channel.id)
      expect(inbox.reload.channel).to eq(channel)
      expect(conversation.reload.inbox).to eq(inbox)
      expect(message.reload.conversation).to eq(conversation)
      expect(channel.reload.reauthorization_required?).to be(true)
      expect(channel.provider_config).to include(
        'api_key' => 'new-token',
        'phone_number_id' => 'phone-1',
        'business_account_id' => 'waba-1',
        'business_id' => 'business-1'
      )
      # ReauthorizationService only commits fresh credentials. The caller clears
      # authorization errors after the remote callback setup succeeds.
      expect(channel.provider_config).to include(
        'authorization_status' => 'reauthorization_required',
        'authorization_error' => include('code' => 190)
      )
    end
  end
end
