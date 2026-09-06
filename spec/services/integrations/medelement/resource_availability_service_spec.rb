require 'rails_helper'

RSpec.describe Integrations::Medelement::ResourceAvailabilityService do
  let(:account) { create(:account) }
  let(:resource) do
    create(
      :scheduling_resource,
      account: account,
      timezone: 'Asia/Almaty',
      custom_attributes: {
        'medelement_specialist_code' => 'specialist-1',
        'medelement_cabinets' => [
          { 'companyCabinetCode' => 'cabinet-1', 'cabinetName' => '101' },
          { 'companyCabinetCode' => 'cabinet-2', 'cabinetName' => '102' }
        ]
      }
    )
  end
  let(:client) { instance_double(Integrations::Medelement::Client) }
  let(:from_time) { Time.zone.parse('2026-09-07 09:00:00 +0500') }
  let(:to_time) { Time.zone.parse('2026-09-07 11:00:00 +0500') }
  let(:slots) do
    [
      { resource_id: resource.id, starts_at: '2026-09-07T09:00:00+05:00', ends_at: '2026-09-07T09:45:00+05:00' },
      { resource_id: resource.id, starts_at: '2026-09-07T10:00:00+05:00', ends_at: '2026-09-07T10:45:00+05:00' }
    ]
  end

  before do
    account.enable_features!('scheduling')
    create(:integrations_hook, :medelement, account: account)
    allow(client).to receive(:timetable).and_return(
      '07.09.2026' => {
        'timetable' => [
          { 'start' => '07.09.2026 09:00', 'end' => '07.09.2026 09:30', 'working' => true },
          { 'start' => '07.09.2026 09:30', 'end' => '07.09.2026 10:00', 'working' => true },
          { 'start' => '07.09.2026 10:00', 'end' => '07.09.2026 10:30', 'working' => true },
          { 'start' => '07.09.2026 10:30', 'end' => '07.09.2026 11:00', 'working' => true }
        ]
      }
    )
  end

  it 'keeps only provider-working slots and chooses a cabinet without an active reception' do
    allow(client).to receive(:get_receptions).with(hash_including(company_cabinet_code: 'cabinet-1')).and_return(
      [{ 'STARTTIME' => '07.09.2026 09:00:00', 'ENDTIME' => '07.09.2026 10:00:00', 'REMOVED' => 0 }]
    )
    allow(client).to receive(:get_receptions).with(hash_including(company_cabinet_code: 'cabinet-2')).and_return(
      [{ 'STARTTIME' => '07.09.2026 10:00:00', 'ENDTIME' => '07.09.2026 11:00:00', 'REMOVED' => 0 }]
    )

    result = described_class.new(resource: resource, from: from_time, to: to_time, slots: slots, client: client).perform

    expect(result.status).to eq('fresh')
    expect(result.slots).to contain_exactly(
      hash_including(
        starts_at: '2026-09-07T09:00:00+05:00',
        availability_source: 'medelement',
        medelement_cabinet_code: 'cabinet-2',
        provider_checked_at: kind_of(String)
      ),
      hash_including(
        starts_at: '2026-09-07T10:00:00+05:00',
        availability_source: 'medelement',
        medelement_cabinet_code: 'cabinet-1',
        provider_checked_at: kind_of(String)
      )
    )
  end

  it 'fails closed instead of returning local slots when the provider is unavailable' do
    allow(client).to receive(:timetable).and_raise(
      Integrations::Medelement::Client::ApiError.new('timeout', status: 504)
    )

    result = described_class.new(resource: resource, from: from_time, to: to_time, slots: slots, client: client).perform

    expect(result).to have_attributes(status: 'unavailable', reason: 'provider_unavailable', slots: [])
  end

  it 'does not treat removed receptions as occupied' do
    allow(client).to receive(:get_receptions).and_return(
      [{ 'STARTTIME' => '07.09.2026 09:00:00', 'ENDTIME' => '07.09.2026 11:00:00', 'REMOVED' => 1 }]
    )

    result = described_class.new(resource: resource, from: from_time, to: to_time, slots: slots, client: client).perform

    expect(result.slots.size).to eq(2)
  end

  it 'fails closed when a reception has no explicit removal state' do
    allow(client).to receive(:get_receptions).and_return(
      [{ 'RECEPTION_CODE' => 'reception-1', 'STARTTIME' => '07.09.2026 09:00:00', 'ENDTIME' => '07.09.2026 11:00:00' }]
    )

    result = described_class.new(resource: resource, from: from_time, to: to_time, slots: slots, client: client).perform

    expect(result).to have_attributes(status: 'unavailable', reason: 'provider_response_invalid', slots: [])
  end

  it 'checks only the cabinet selected for the mutation' do
    allow(client).to receive(:get_receptions).with(hash_including(company_cabinet_code: 'cabinet-1')).and_return(
      [{ 'STARTTIME' => '07.09.2026 09:00:00', 'ENDTIME' => '07.09.2026 11:00:00', 'REMOVED' => 0 }]
    )

    result = described_class.new(
      resource: resource,
      from: from_time,
      to: to_time,
      slots: slots,
      client: client,
      cabinet_code: 'cabinet-1'
    ).perform

    expect(result.slots).to be_empty
    expect(client).not_to have_received(:get_receptions).with(hash_including(company_cabinet_code: 'cabinet-2'))
  end

  it 'excludes the current reception while checking a move' do
    allow(client).to receive(:get_receptions).and_return(
      [
        {
          'RECEPTION_CODE' => 'reception-1',
          'STARTTIME' => '07.09.2026 09:00:00',
          'ENDTIME' => '07.09.2026 11:00:00',
          'REMOVED' => 0
        }
      ]
    )

    result = described_class.new(
      resource: resource,
      from: from_time,
      to: to_time,
      slots: slots,
      client: client,
      cabinet_code: 'cabinet-1',
      exclude_reception_code: 'reception-1'
    ).perform

    expect(result.slots.size).to eq(2)
  end
end
