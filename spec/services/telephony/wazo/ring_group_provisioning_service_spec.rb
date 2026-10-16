# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telephony::Wazo::RingGroupProvisioningService do
  let(:account) { create(:account) }
  let(:connection) do
    create(:telephony_provider_connection, account: account, provider_kind: 'wazo', status: 'active')
  end
  let(:channel) do
    create(:channel_voice, account: account, provider: 'wazo', phone_number: '+77085012233',
                           provider_config: { number_ref: 'altel-did-1', provider_connection_id: connection.id,
                                              routing_mode: 'operator' })
  end
  let(:inbox) { channel.inbox }
  let!(:binding) { Telephony::NumberBinding.sync_from_voice_channel!(channel) }
  let(:user1) { create(:user, account: account, role: :agent) }
  let(:user2) { create(:user, account: account, role: :agent) }
  let!(:profile1) do
    create(:telephony_sip_profile, account: account, inbox: inbox, provider_connection: connection,
                                   user: user1, internal_extension: '1001', status: 'active', enabled: true,
                                   metadata: { 'wazo_user_uuid' => 'wazo-u-1' })
  end
  let!(:profile2) do
    create(:telephony_sip_profile, account: account, inbox: inbox, provider_connection: connection,
                                   user: user2, internal_extension: '1002', status: 'active', enabled: true,
                                   metadata: { 'wazo_user_uuid' => 'wazo-u-2' })
  end
  let(:client) { instance_double(Telephony::Wazo::ApiClient) }
  let(:service) { described_class.new(account: account, inbox: inbox, client: client, sip_context: 'ctx-internal-1') }

  it 'creates a Wazo ring group, syncs all active inbox operator members, binds extension 2001, and routes the DID incall to the group' do
    allow(client).to receive(:groups).and_return([])
    expect(client).to receive(:create_group).with(
      label: "OneLink Inbox #{inbox.id}",
      ring_strategy: 'all',
      timeout: 45,
      user_timeout: 25,
      retry_delay: 5,
      ring_in_use: false
    ).and_return('id' => 1, 'uuid' => 'grp-uuid-1')

    expect(client).to receive(:update_group_user_members).with(
      'grp-uuid-1',
      [
        { uuid: 'wazo-u-1', priority: 1 },
        { uuid: 'wazo-u-2', priority: 2 }
      ]
    )

    allow(client).to receive(:extensions).and_return([])
    expect(client).to receive(:create_extension).with(context: 'ctx-internal-1', exten: '2001').and_return('id' => 7)
    expect(client).to receive(:associate_group_extension).with('grp-uuid-1', 7)

    allow(client).to receive(:incalls).and_return([
      { 'id' => 1, 'extensions' => [{ 'exten' => '77085012233' }] }
    ])
    expect(client).to receive(:update_incall).with(1, destination: { type: 'group', group_id: 1, ring_time: 45 })

    result = service.sync!(ring_strategy: 'all', group_extension: '2001')

    expect(result).to eq(
      group_id: 1,
      group_uuid: 'grp-uuid-1',
      group_label: "OneLink Inbox #{inbox.id}",
      ring_strategy: 'all',
      member_user_uuids: %w[wazo-u-1 wazo-u-2],
      group_extension: '2001',
      group_extension_id: 7,
      bound_incall_ids: [1]
    )
  end
end
