require 'rails_helper'

RSpec.describe Whatsapp::CoexistenceSyncReconciliationService do
  let(:channel) do
    create(
      :channel_whatsapp,
      provider: 'whatsapp_cloud',
      validate_provider_config: false,
      sync_templates: false,
      provider_config: {
        'api_key' => 'token',
        'phone_number_id' => 'phone-1',
        'business_account_id' => 'waba-1',
        'embedded_signup_flow' => 'coexistence',
        'coexistence_sync' => {
          'generation' => 'generation-1',
          'state' => 'pending',
          'deadline_at' => 1.hour.from_now.iso8601
        }
      }
    )
  end

  it 'reconciles accepted and unknown requests from their successful webhook fields' do
    update_sync(
      'state' => 'request_outcome_unknown',
      'history_request_state' => 'outcome_unknown',
      'smb_app_state_sync_request_state' => 'requested'
    )
    allow(Whatsapp::CoexistenceSyncJob).to receive(:perform_later)
    service = described_class.new(channel)

    expect(service.reconcile_webhook!('history')).to be(true)
    expect(service.reconcile_webhook!('smb_app_state_sync')).to be(true)

    sync = channel.reload.provider_config['coexistence_sync']
    expect(sync).to include(
      'state' => 'completed',
      'history_request_state' => 'completed',
      'smb_app_state_sync_request_state' => 'completed'
    )
    expect(sync['completed_at']).to be_present
    expect(Whatsapp::CoexistenceSyncJob).not_to have_received(:perform_later)
  end

  it 'continues with an unclaimed request after the unknown request webhook arrives' do
    update_sync('state' => 'request_outcome_unknown', 'history_request_state' => 'outcome_unknown')
    allow(Whatsapp::CoexistenceSyncJob).to receive(:perform_later)

    described_class.new(channel).reconcile_webhook!('history')

    expect(Whatsapp::CoexistenceSyncJob).to have_received(:perform_later).with(channel.id, 'generation-1')
  end

  it 'accepts a webhook that arrives after Meta accepted a request but before the worker persisted it' do
    update_sync(
      'state' => 'requesting',
      'history_request_state' => 'requesting',
      'history_request_started_at' => 1.minute.ago.iso8601,
      'smb_app_state_sync_request_state' => 'completed'
    )

    expect(described_class.new(channel).reconcile_webhook!('history')).to be(true)
    expect(channel.reload.provider_config['coexistence_sync']).to include(
      'state' => 'completed',
      'history_request_state' => 'completed'
    )
  end

  %w[history_failed history_declined].each do |terminal_state|
    it "does not overwrite terminal #{terminal_state} with a late success webhook" do
      update_sync(
        'state' => terminal_state,
        'history_request_state' => terminal_state,
        'history_last_error' => 'provider_terminal_history_error'
      )
      expect(Whatsapp::CoexistenceSyncJob).not_to receive(:perform_later)

      expect(described_class.new(channel).reconcile_webhook!('history')).to be(false)
      expect(channel.reload.provider_config['coexistence_sync']).to include(
        'state' => terminal_state,
        'history_request_state' => terminal_state,
        'history_last_error' => 'provider_terminal_history_error'
      )
    end
  end

  it 'keeps an unknown request pending until its reconciliation deadline' do
    update_sync('state' => 'request_outcome_unknown', 'history_request_state' => 'outcome_unknown')

    expect(described_class.new(channel).reconcile_unknown_outcome!).to eq(:waiting)
    expect(channel.reload.provider_config.dig('coexistence_sync', 'state')).to eq('request_outcome_unknown')
  end

  it 'converts a stale in-flight claim to an unknown outcome without repeating the one-time request' do
    update_sync(
      'state' => 'requesting',
      'history_request_state' => 'requesting',
      'history_request_started_at' => 16.minutes.ago.iso8601
    )

    expect(described_class.new(channel).reconcile_unknown_outcome!).to eq(:waiting)
    expect(channel.reload.provider_config['coexistence_sync']).to include(
      'state' => 'request_outcome_unknown',
      'history_request_state' => 'outcome_unknown'
    )
  end

  it 'keeps a fresh in-flight claim leased to the active worker' do
    update_sync(
      'state' => 'requesting',
      'history_request_state' => 'requesting',
      'history_request_started_at' => 1.minute.ago.iso8601
    )

    expect(described_class.new(channel).reconcile_unknown_outcome!).to eq(:waiting)
    expect(channel.reload.provider_config['coexistence_sync']).to include(
      'state' => 'requesting',
      'history_request_state' => 'requesting'
    )
  end

  it 'requires explicit reauthorization after an unknown request reaches its deadline' do
    update_sync(
      'state' => 'request_outcome_unknown',
      'history_request_state' => 'outcome_unknown',
      'deadline_at' => 1.minute.ago.iso8601
    )
    expect(channel).to receive(:prompt_reauthorization!)

    expect(described_class.new(channel).reconcile_unknown_outcome!).to eq(:manual_recovery_required)
    expect(channel.reload.provider_config['coexistence_sync']).to include(
      'state' => 'manual_recovery_required',
      'history_request_state' => 'manual_recovery_required'
    )
  end

  it 'requires explicit reauthorization when an in-flight claim reaches the synchronization deadline' do
    update_sync(
      'state' => 'requesting',
      'history_request_state' => 'requesting',
      'history_request_started_at' => 1.minute.ago.iso8601,
      'deadline_at' => 1.minute.ago.iso8601
    )
    expect(channel).to receive(:prompt_reauthorization!)

    expect(described_class.new(channel).reconcile_unknown_outcome!).to eq(:manual_recovery_required)
    expect(channel.reload.provider_config['coexistence_sync']).to include(
      'state' => 'manual_recovery_required',
      'history_request_state' => 'manual_recovery_required'
    )
  end

  it 'makes retry exhaustion durable without re-running provider validation' do
    update_sync('state' => 'failed', 'history_request_state' => 'failed')
    allow(channel).to receive(:validate_provider_config).and_raise('provider unavailable')
    expect(channel).to receive(:prompt_reauthorization!).and_call_original

    expect(described_class.new(channel).require_manual_recovery!(StandardError.new('access_token=token failed')))
      .to eq(:manual_recovery_required)

    sync = channel.reload.provider_config['coexistence_sync']
    expect(sync).to include(
      'state' => 'manual_recovery_required',
      'history_request_state' => 'manual_recovery_required'
    )
    expect(channel.reauthorization_required?).to be(true)
    expect(sync['last_error']).not_to include('=token')
  end

  it 'does not let retry exhaustion from an old generation prompt reauthorization' do
    update_sync('generation' => 'generation-2', 'state' => 'pending')
    expect(channel).not_to receive(:prompt_reauthorization!)

    expect(
      described_class.new(channel).require_manual_recovery!(
        StandardError.new('old failure'), generation: 'generation-1'
      )
    ).to eq(:stale)
    expect(channel.reload.provider_config.dig('coexistence_sync', 'state')).to eq('pending')
  end

  def update_sync(attributes)
    config = channel.provider_config.deep_dup
    config['coexistence_sync'].merge!(attributes)
    channel.update!(provider_config: config)
  end
end
