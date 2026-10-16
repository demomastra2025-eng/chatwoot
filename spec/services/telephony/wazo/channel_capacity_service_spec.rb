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
      { 'call_id' => 'c1', 'caller_id_number' => '+77019998877', 'peer_caller_id_number' => '77085012233', 'is_caller' => false },
      { 'call_id' => 'c2', 'caller_id_number' => '1001', 'peer_caller_id_number' => '+77021112233', 'is_caller' => true },
      { 'call_id' => 'c3', 'caller_id_number' => '9999', 'peer_caller_id_number' => '+77050000000', 'is_caller' => true }
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
    expect(connection.metadata['wazo_last_channel_limit_reason']).to eq('SIP 486 Busy Here')
  end
end
