# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telephony::Wazo::ChannelCapacityService do
  let(:account) { create(:account) }
  let(:connection) do
    create(:telephony_provider_connection, account: account, provider_kind: 'wazo', status: 'active',
                                           metadata: { 'max_channels' => 10, 'reserved_inbound_channels' => 2 })
  end
  let(:channel) do
    create(:channel_voice, account: account, provider: 'wazo', phone_number: '+77085012233',
                           provider_config: { number_ref: 'altel-did-1', provider_connection_id: connection.id,
                                              routing_mode: 'operator' })
  end
  let(:inbox) { channel.inbox }
  let!(:binding) { Telephony::NumberBinding.sync_from_voice_channel!(channel) }
  let(:user) { create(:user, account: account, role: :agent) }
  let!(:profile) do
    create(:telephony_sip_profile, account: account, inbox: inbox, provider_connection: connection,
                                   user: user, internal_extension: '1001', status: 'active', enabled: true)
  end
  let(:client) { instance_double(Telephony::Wazo::ApiClient) }
  let(:service) { described_class.new(connection: connection, client: client) }

  it 'calculates active inbound/outbound channels, peak today, and outbound availability' do
    allow(client).to receive(:active_calls).and_return([
                                                         { 'call_id' => 'c1', 'caller_id_number' => '+77019998877',
                                                           'peer_caller_id_number' => '77085012233', 'is_caller' => false },
                                                         { 'call_id' => 'c2', 'caller_id_number' => '1001',
                                                           'peer_caller_id_number' => '+77021112233', 'is_caller' => true },
                                                         { 'call_id' => 'c3', 'caller_id_number' => '9999',
                                                           'peer_caller_id_number' => '+77050000000', 'is_caller' => true }
                                                       ])

    snap = service.snapshot

    expect(snap).to include(
      connection_id: connection.id,
      active_channels: 2,
      inbound_channels: 1,
      outbound_channels: 1,
      peak_today: 2,
      configured_max_channels: 10,
      effective_max_channels: 10,
      reserved_inbound_channels: 2,
      outbound_available: true
    )
  end

  it 'blocks outbound calls when active channels reach the inbound reservation threshold (8 of 10)' do
    expect(service.outbound_allowed?(active_count: 7)).to be(true)
    expect(service.outbound_allowed?(active_count: 8)).to be(false)
  end

  it 'auto-detects the provider channel limit when a congestion rejection occurs while channels are active' do
    detected = service.report_provider_rejection!(reason_code: 'SIP 486 Busy Here', active_count: 5)

    expect(detected).to eq(5)
    expect(connection.reload.metadata['wazo_detected_channel_limit']).to eq(5)
    expect(connection.metadata['detected_channel_limit']).to eq(5)
    expect(connection.metadata['detection_source']).to eq('runtime_congestion')
    expect(connection.metadata['wazo_last_channel_limit_reason']).to eq('SIP 486 Busy Here')
  end

  it 'runs a stepped non-answered loopback ring probe (0 KZT billed) and persists detected_channel_limit and ai_max_concurrent_calls' do
    cancelled_legs = []
    probe_runner = lambda do |step:, leg_id:, cancel_before_answer:|
      expect(cancel_before_answer).to be(true)
      if step <= 3
        {
          accepted: true,
          ringing: true,
          answered: false,
          cancel: -> { cancelled_legs << leg_id }
        }
      else
        {
          accepted: false,
          answered: false,
          reason_code: 'SIP 486 Busy Here'
        }
      end
    end

    result = described_class.probe_capacity!(
      connection: connection,
      max_probe_channels: 6,
      probe_runner: probe_runner
    )

    expect(result).to include(
      detected_channel_limit: 3,
      ai_max_concurrent_calls: 3,
      answered: false,
      billed_amount_kzt: 0,
      detection_source: 'active_probe',
      rejection_reason: 'SIP 486 Busy Here'
    )
    expect(cancelled_legs.size).to eq(3)
    expect(connection.reload.metadata).to include(
      'detected_channel_limit' => 3,
      'wazo_detected_channel_limit' => 3,
      'max_channels' => 3,
      'detection_source' => 'active_probe'
    )
    expect(connection.metadata['last_channel_probe_at']).to be_present
  end

  it 'falls back to the carrier preset default channel ceiling during loopback simulation when max_channels is not yet configured' do
    unconfigured_conn = create(
      :telephony_provider_connection,
      account: account,
      provider_kind: 'wazo',
      status: 'active',
      metadata: { 'carrier_kind' => 'kazakhtelecom' }
    )

    result = described_class.probe_capacity!(
      connection: unconfigured_conn,
      max_probe_channels: 10
    )

    expect(result[:detected_channel_limit]).to eq(10)
    expect(result[:accepted_channels]).to eq(10)
    expect(result[:cancelled_legs]).to eq(10)
    expect(result[:answered]).to be(false)
    expect(result[:billed_amount_kzt]).to eq(0)
  end
end
