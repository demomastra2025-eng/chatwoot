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
      carrier_kind: 'custom',
      trunk_endpoint_uuid: 'ep-trunk-1',
      trunk_id: 10,
      outcall_id: 20,
      incall_id: 30
    )
  end

  it 'applies carrier preset defaults (send_pai for Kazakhtelecom) and routes incall to a Wazo Ring Group' do
    allow(client).to receive(:sip_endpoints).and_return([])
    expect(client).to receive(:create_sip_endpoint).with(
      hash_including(
        name: 'trunk_77273001122',
        label: 'OneLink Kazakhtelecom (iD Phone) Trunk 77273001122',
        endpoint_section_options: array_including(
          ['from_domain', 'sip.telecom.kz'],
          ['send_pai', 'yes']
        )
      )
    ).and_return('uuid' => 'ep-kt-1')

    allow(client).to receive(:trunks).and_return([])
    expect(client).to receive(:create_trunk).with(context: 'ctx-incall-1').and_return('id' => 11)
    expect(client).to receive(:associate_trunk_sip_endpoint).with(11, 'ep-kt-1')

    allow(client).to receive(:outcalls).and_return([])
    expect(client).to receive(:create_outcall).and_return('id' => 21)
    expect(client).to receive(:associate_outcall_trunks).with(21, [11])

    allow(client).to receive(:extensions).and_return([])
    allow(client).to receive(:create_extension).and_return('id' => 201)
    allow(client).to receive(:associate_outcall_extension)

    allow(client).to receive(:incalls).and_return([])
    expect(client).to receive(:create_incall).with(
      destination: { type: 'group', group_id: 7, ring_time: 45 },
      description: 'OneLink DID 77273001122'
    ).and_return('id' => 31)
    expect(client).to receive(:associate_incall_extension).with(31, 201)

    result = service.provision_trunk!(
      did: '+7 727 300 11 22',
      carrier_kind: 'kazakhtelecom',
      trunk_username: 'kt_user',
      trunk_password: 'kt_password',
      target_wazo_group_id: 7
    )

    expect(result).to eq(
      did: '77273001122',
      carrier_kind: 'kazakhtelecom',
      trunk_endpoint_uuid: 'ep-kt-1',
      trunk_id: 11,
      outcall_id: 21,
      incall_id: 31
    )
  end
end
