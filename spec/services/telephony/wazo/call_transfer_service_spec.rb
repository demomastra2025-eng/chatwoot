# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telephony::Wazo::CallTransferService do
  let(:account) { instance_double(Account, id: 530, telephony_sip_profiles: profile_relation) }
  let(:profile_relation) { double }
  let(:client) { instance_double(Telephony::Wazo::ApiClient) }
  let(:service) { described_class.new(account: account, client: client, default_context: 'ctx-master-internal-1') }

  it 'initiates a blind transfer by resolving the bridged peer call and operator extension' do
    target_profile = instance_double(
      Telephony::SipProfile,
      internal_extension: '1002',
      metadata: { 'wazo_sip_context' => 'ctx-master-internal-1' }
    )
    allow(profile_relation).to receive(:where).with(user_id: 42, status: 'active', enabled: true).and_return([target_profile])
    allow(client).to receive(:active_call).with('call-operator-1').and_return(
      'call_id' => 'call-operator-1',
      'talking_to' => { 'call-patient-1' => 'user-uuid' }
    )
    expect(client).to receive(:initiate_transfer).with(
      transferred_call: 'call-patient-1',
      initiator_call: 'call-operator-1',
      context: 'ctx-master-internal-1',
      exten: '1002',
      flow: 'blind',
      variables: {},
      timeout: 30
    ).and_return('id' => 'tx-123', 'status' => 'starting')

    result = service.transfer!(initiator_call_id: 'call-operator-1', target_user_id: 42, flow: 'blind')

    expect(result).to eq(
      transfer_id: 'tx-123',
      status: 'starting',
      flow: 'blind',
      initiator_call_id: 'call-operator-1',
      transferred_call_id: 'call-patient-1',
      target_extension: '1002',
      context: 'ctx-master-internal-1'
    )
  end

  it 'completes and cancels an attended transfer' do
    expect(client).to receive(:complete_transfer).with('tx-123')
    expect(client).to receive(:cancel_transfer).with('tx-456')

    expect(service.complete!(transfer_id: 'tx-123')).to eq(transfer_id: 'tx-123', status: 'completed')
    expect(service.cancel!(transfer_id: 'tx-456')).to eq(transfer_id: 'tx-456', status: 'cancelled')
  end
end
