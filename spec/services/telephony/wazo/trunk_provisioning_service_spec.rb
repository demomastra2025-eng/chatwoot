# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telephony::Wazo::TrunkProvisioningService do
  let(:client) { instance_double(Telephony::Wazo::ApiClient) }
  let(:service) do
    described_class.new(
      client: client,
      incall_context: 'ctx-incall-1',
      outcall_context: 'ctx-outcall-1'
    )
  end

  it 'provisions a SIP trunk endpoint, trunk, outcall dial patterns, and incall DID routing in Wazo' do
    allow(client).to receive(:sip_endpoints).and_return([])
    expect(client).to receive(:create_sip_endpoint).with(
      hash_including(
        name: 'trunk_77085012233',
        endpoint_section_options: array_including(
          ['from_user', 'f9bOCzgF'],
          ['from_domain', 'astpbx.tele2.kz'],
          ['transport', 'transport-udp']
        )
      )
    ).and_return('uuid' => 'ep-trunk-1')

    allow(client).to receive(:trunks).and_return([])
    expect(client).to receive(:create_trunk).with(context: 'ctx-incall-1').and_return('id' => 10)
    expect(client).to receive(:associate_trunk_sip_endpoint).with(10, 'ep-trunk-1')

    allow(client).to receive(:outcalls).and_return([])
    expect(client).to receive(:create_outcall).and_return('id' => 20)
    expect(client).to receive(:associate_outcall_trunks).with(20, [10])

    allow(client).to receive(:extensions).and_return([])
    expect(client).to receive(:create_extension).with(context: 'ctx-outcall-1', exten: '_7XXXXXXXXXX').and_return('id' => 101)
    expect(client).to receive(:create_extension).with(context: 'ctx-outcall-1', exten: '_+7XXXXXXXXXX').and_return('id' => 102)
    expect(client).to receive(:create_extension).with(context: 'ctx-outcall-1', exten: '_87XXXXXXXXX').and_return('id' => 103)
    expect(client).to receive(:associate_outcall_extension).with(20, 101, hash_including(caller_id: '77085012233', strip_digits: 0))
    expect(client).to receive(:associate_outcall_extension).with(20, 102, hash_including(caller_id: '77085012233', strip_digits: 1))
    expect(client).to receive(:associate_outcall_extension).with(20, 103, hash_including(caller_id: '77085012233', strip_digits: 1, external_prefix: '7'))

    allow(client).to receive(:incalls).and_return([])
    expect(client).to receive(:create_incall).with(
      destination: { type: 'user', user_id: 3, ring_time: 45 },
      description: 'OneLink DID 77085012233'
    ).and_return('id' => 30)
    expect(client).to receive(:create_extension).with(context: 'ctx-incall-1', exten: '77085012233').and_return('id' => 104)
    expect(client).to receive(:associate_incall_extension).with(30, 104)

    result = service.provision_trunk!(
      did: '+7 708 501 22 33',
      trunk_username: 'f9bOCzgF',
      trunk_password: 'secret',
      trunk_domain: 'astpbx.tele2.kz',
      trunk_host: '91.185.24.71',
      target_wazo_user_id: 3
    )

    expect(result).to eq(
      did: '77085012233',
      trunk_endpoint_uuid: 'ep-trunk-1',
      trunk_id: 10,
      outcall_id: 20,
      incall_id: 30
    )
  end
end
