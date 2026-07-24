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
    stub_request(:get, 'https://graph.facebook.com/v22.0/waba-1/message_templates')
      .to_return(status: 200, body: { data: [] }.to_json, headers: { 'Content-Type' => 'application/json' })
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
    stub_request(:get, 'https://graph.facebook.com/v22.0/waba-destination/message_templates')
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
      expect(channel.provider_config).not_to include('authorization_status')
      expect(channel.provider_config).not_to include('authorization_error')
    end
  end
end
