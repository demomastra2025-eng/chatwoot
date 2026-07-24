require 'rails_helper'

RSpec.describe Whatsapp::CoexistenceSyncService do
  let(:channel) do
    channel = create(
      :channel_whatsapp,
      provider: 'whatsapp_cloud',
      sync_templates: false,
      validate_provider_config: false,
      provider_config: {
        'api_key' => 'coexistence_token',
        'phone_number_id' => 'phone-1',
        'business_account_id' => 'waba-1',
        'embedded_signup_flow' => 'coexistence',
        'coexistence_sync' => {
          'generation' => 'generation-1',
          'state' => 'pending',
          'deadline_at' => 2.hours.from_now.iso8601
        }
      }
    )
    channel.update!(provider_config: {
                      'api_key' => 'coexistence_token',
                      'phone_number_id' => 'phone-1',
                      'business_account_id' => 'waba-1',
                      'embedded_signup_flow' => 'coexistence',
                      'coexistence_sync' => {
                        'generation' => 'generation-1',
                        'state' => 'pending',
                        'deadline_at' => 2.hours.from_now.iso8601
                      }
                    })
    channel
  end
  let(:api_client) { instance_double(Whatsapp::FacebookApiClient) }

  before do
    allow(Whatsapp::FacebookApiClient).to receive(:new).with('coexistence_token').and_return(api_client)
    allow(api_client).to receive(:request_smb_app_data)
      .with('phone-1', 'smb_app_state_sync').and_return('request_id' => 'contacts-request')
    allow(api_client).to receive(:request_smb_app_data)
      .with('phone-1', 'history').and_return('request_id' => 'history-request')
  end

  it 'keeps the WABA lock held through both one-time provider requests' do
    lock = instance_double(Whatsapp::WabaLock)
    lock_held = false
    allow(Whatsapp::WabaLock).to receive(:new).with('waba-1').and_return(lock)
    allow(lock).to receive(:with_lock) do |&block|
      lock_held = true
      block.call
    ensure
      lock_held = false
    end
    expect(api_client).to receive(:request_smb_app_data).twice do
      expect(lock_held).to be(true)
      { 'request_id' => SecureRandom.uuid }
    end

    described_class.new(channel).perform
  end

  it 'rejects an inbox pending deletion before calling Meta' do
    channel.inbox.update!(deleting_at: Time.current)
    expect(api_client).not_to receive(:request_smb_app_data)

    expect { described_class.new(channel).perform }.to raise_error(ArgumentError, 'Active WhatsApp inbox is required')
  end

  it 'requests both mandatory one-time syncs and persists their request ids' do
    described_class.new(channel).perform

    sync = channel.reload.provider_config['coexistence_sync']
    expect(sync).to include(
      'state' => 'requested',
      'smb_app_state_sync_request_id' => 'contacts-request',
      'history_request_id' => 'history-request'
    )
  end

  it 'accepts the official success-only response without repeating the one-time requests' do
    allow(api_client).to receive(:request_smb_app_data).and_return('success' => true)

    described_class.new(channel).perform

    sync = channel.reload.provider_config['coexistence_sync']
    expect(sync).to include(
      'state' => 'requested',
      'smb_app_state_sync_request_state' => 'requested',
      'history_request_state' => 'requested'
    )
    expect(api_client).not_to receive(:request_smb_app_data)
    described_class.new(channel).perform
  end

  it 'is idempotent after both requests were persisted' do
    described_class.new(channel).perform
    expect(api_client).not_to receive(:request_smb_app_data)

    described_class.new(channel).perform
  end

  it 'does not repeat either one-time request after any provider error following the second POST' do
    response = Struct.new(:body, :code, :parsed_response).new('rejected history request', 400, {})
    api_error = Whatsapp::FacebookApiClient::Error.new('History request failed', response)
    allow(api_client).to receive(:request_smb_app_data).with('phone-1', 'history').and_raise(api_error)

    expect { described_class.new(channel).perform }.to raise_error(described_class::RequestOutcomeUnknownError)
    sync = channel.reload.provider_config['coexistence_sync']
    expect(sync).to include(
      'state' => 'request_outcome_unknown',
      'smb_app_state_sync_request_id' => 'contacts-request',
      'history_request_state' => 'outcome_unknown'
    )

    expect(api_client).not_to receive(:request_smb_app_data).with('phone-1', 'smb_app_state_sync')
    expect(api_client).not_to receive(:request_smb_app_data).with('phone-1', 'history')
    expect { described_class.new(channel).perform }
      .to raise_error(described_class::RequestOutcomeUnknownError, /refusing a duplicate/)
  end

  it 'does not repeat a one-time request after a 5xx response with an unknown remote outcome' do
    response = Struct.new(:body, :code, :parsed_response).new('temporary history failure', 503, {})
    api_error = Whatsapp::FacebookApiClient::Error.new('History request failed', response)
    allow(api_client).to receive(:request_smb_app_data).with('phone-1', 'history').and_raise(api_error)

    expect do
      described_class.new(channel).perform
    end.to raise_error(described_class::RequestOutcomeUnknownError)
    expect(channel.reload.provider_config['coexistence_sync']).to include(
      'state' => 'request_outcome_unknown',
      'smb_app_state_sync_request_id' => 'contacts-request',
      'history_request_state' => 'outcome_unknown'
    )

    expect(api_client).not_to receive(:request_smb_app_data).with('phone-1', 'history')
    expect do
      described_class.new(channel).perform
    end.to raise_error(described_class::RequestOutcomeUnknownError, /refusing a duplicate/)
  end

  it 'does not repeat a one-time request after a network timeout with an unknown outcome' do
    allow(api_client).to receive(:request_smb_app_data).with('phone-1', 'history').and_raise(Timeout::Error)

    expect do
      described_class.new(channel).perform
    end.to raise_error(described_class::RequestOutcomeUnknownError)
    sync = channel.reload.provider_config['coexistence_sync']
    expect(sync).to include(
      'state' => 'request_outcome_unknown',
      'smb_app_state_sync_request_id' => 'contacts-request',
      'history_request_state' => 'outcome_unknown'
    )

    expect(api_client).not_to receive(:request_smb_app_data).with('phone-1', 'history')
    expect do
      described_class.new(channel).perform
    end.to raise_error(described_class::RequestOutcomeUnknownError, /refusing a duplicate/)
  end

  it 'refuses a duplicate job after another worker atomically claims a one-time request' do
    config = channel.provider_config.deep_dup
    config['coexistence_sync']['smb_app_state_sync_request_state'] = 'requesting'
    channel.update!(provider_config: config)

    expect(api_client).not_to receive(:request_smb_app_data)
    expect do
      described_class.new(channel).perform
    end.to raise_error(described_class::RequestAlreadyClaimedError, /refusing a duplicate/)
    expect(channel.reload.provider_config.dig('coexistence_sync', 'state')).to eq('requesting')
  end

  it 'does not overwrite terminal manual recovery when a provider request completes late' do
    allow(api_client).to receive(:request_smb_app_data).with('phone-1', 'smb_app_state_sync') do
      config = channel.reload.provider_config.deep_dup
      config['coexistence_sync'].merge!(
        'state' => 'manual_recovery_required',
        'smb_app_state_sync_request_state' => 'manual_recovery_required',
        'history_request_state' => 'manual_recovery_required',
        'recovery_required_at' => Time.current.iso8601
      )
      channel.persist_provider_config_state!(config)
      { 'request_id' => 'late-provider-request' }
    end
    expect(api_client).not_to receive(:request_smb_app_data).with('phone-1', 'history')

    described_class.new(channel).perform

    expect(channel.reload.provider_config['coexistence_sync']).to include(
      'state' => 'manual_recovery_required',
      'smb_app_state_sync_request_state' => 'manual_recovery_required',
      'history_request_state' => 'manual_recovery_required'
    )
  end

  it 'preserves webhook completion when the provider response is persisted later' do
    config = channel.provider_config.deep_dup
    config['coexistence_sync']['history_request_state'] = 'completed'
    channel.update!(provider_config: config)
    allow(api_client).to receive(:request_smb_app_data).with('phone-1', 'smb_app_state_sync') do
      Whatsapp::CoexistenceSyncReconciliationService.new(channel).reconcile_webhook!('smb_app_state_sync')
      { 'request_id' => 'late-provider-request' }
    end
    expect(api_client).not_to receive(:request_smb_app_data).with('phone-1', 'history')

    described_class.new(channel).perform

    expect(channel.reload.provider_config['coexistence_sync']).to include(
      'state' => 'completed',
      'smb_app_state_sync_request_state' => 'completed',
      'smb_app_state_sync_request_id' => 'late-provider-request',
      'history_request_state' => 'completed'
    )
  end

  it 'does not call the one-time endpoints after the 24-hour deadline' do
    config = channel.provider_config.deep_dup
    config['coexistence_sync']['deadline_at'] = 1.minute.ago.iso8601
    channel.update!(provider_config: config)

    expect(api_client).not_to receive(:request_smb_app_data)
    expect { described_class.new(channel).perform }.to raise_error(/deadline has expired/)
    expect(channel.reload.provider_config.dig('coexistence_sync', 'state')).to eq('failed')
  end
end
