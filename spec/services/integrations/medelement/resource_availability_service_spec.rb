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

  it 'uses split timetable reads for a live search longer than seven calendar days' do
    payload = (Date.new(2026, 9, 7)..Date.new(2026, 9, 15)).to_h do |date|
      [date.strftime('%d.%m.%Y'), { 'specialistWorkingHours' => 'day off', 'timetable' => [] }]
    end.merge(
      '07.09.2026' => { 'timetable' => [
        { 'start' => '07.09.2026 09:00', 'end' => '07.09.2026 11:00', 'working' => true }
      ] }
    )
    allow(client).to receive(:timetable_range).and_return(payload)
    allow(client).to receive(:get_receptions).and_return([])

    result = described_class.new(resource: resource, from: from_time, to: to_time + 8.days,
                                 slots: slots, client: client).perform

    expect(result.status).to eq('fresh')
    expect(client).to have_received(:timetable_range).with(
      specialist_code: 'specialist-1', starts_on: Date.new(2026, 9, 7), ends_on: Date.new(2026, 9, 15)
    )
    expect(client).not_to have_received(:timetable)
  end

  it 'rejects a manual interval whose tail overlaps a reception in the chosen cabinet' do
    allow(client).to receive(:get_receptions).and_return(
      [{ 'STARTTIME' => '07.09.2026 10:00:00', 'ENDTIME' => '07.09.2026 10:30:00', 'REMOVED' => 0 }]
    )
    manual = slots.first.merge(ends_at: '2026-09-07T10:15:00+05:00')

    result = described_class.new(resource: resource, from: from_time, to: to_time,
                                 slots: [manual], cabinet_code: 'cabinet-1', client: client).perform

    expect(result).to have_attributes(status: 'fresh', slots: [])
  end

  it 'rejects a manual interval spanning a gap in the confirmed doctor graph' do
    allow(client).to receive(:timetable).and_return(
      '07.09.2026' => { 'timetable' => [
        { 'start' => '07.09.2026 09:00', 'end' => '07.09.2026 10:00', 'working' => true },
        { 'start' => '07.09.2026 10:15', 'end' => '07.09.2026 11:00', 'working' => true }
      ] }
    )
    allow(client).to receive(:get_receptions).and_return([])
    manual = slots.first.merge(ends_at: '2026-09-07T10:30:00+05:00')

    result = described_class.new(resource: resource, from: from_time, to: to_time,
                                 slots: [manual], client: client).perform

    expect(result).to have_attributes(status: 'fresh', slots: [])
  end

  it 'does not use another cabinet graph to justify the chosen cabinet interval' do
    allow(client).to receive(:timetable).and_return(
      '07.09.2026' => { 'timetable' => [
        { 'start' => '07.09.2026 09:00', 'end' => '07.09.2026 11:00', 'working' => true, 'cabinetCode' => 'cabinet-2' }
      ] }
    )
    allow(client).to receive(:get_receptions).and_return([])

    result = described_class.new(resource: resource, from: from_time, to: to_time,
                                 slots: slots, cabinet_code: 'cabinet-1', client: client).perform

    expect(result).to have_attributes(status: 'fresh', slots: [])
  end

  it 'reads and parses provider dates in the integration zone when the resource zone differs' do
    resource.update!(timezone: 'America/New_York')
    zone = ActiveSupport::TimeZone['Asia/Almaty']
    from = zone.local(2026, 9, 7, 0, 30)
    slot = { resource_id: resource.id, starts_at: from.iso8601, ends_at: (from + 30.minutes).iso8601 }
    allow(client).to receive(:timetable).and_return(
      '07.09.2026' => { 'timetable' => [
        { 'start' => '07.09.2026 00:30', 'end' => '07.09.2026 01:00', 'working' => true }
      ] }
    )
    allow(client).to receive(:get_receptions).and_return([])

    result = described_class.new(resource: resource, from: from, to: from + 30.minutes,
                                 slots: [slot], client: client).perform

    expect(result.slots).to contain_exactly(hash_including(resource_id: resource.id))
    expect(client).to have_received(:timetable).with(
      specialist_code: 'specialist-1', starts_on: Date.new(2026, 9, 7), ends_on: Date.new(2026, 9, 7)
    )
  end

  it 'fails closed instead of returning local slots when the provider is unavailable' do
    allow(client).to receive(:timetable).and_raise(
      Integrations::Medelement::Client::ApiError.new('timeout', status: 504)
    )

    result = described_class.new(resource: resource, from: from_time, to: to_time, slots: slots, client: client).perform

    expect(result).to have_attributes(status: 'unavailable', reason: 'provider_unavailable', slots: [])
  end

  it 'accepts numeric and string working flags from the timetable' do
    allow(client).to receive(:timetable).and_return(
      '07.09.2026' => {
        'timetable' => [
          { 'start' => '07.09.2026 09:00', 'end' => '07.09.2026 10:00', 'working' => 1 },
          { 'start' => '07.09.2026 10:00', 'end' => '07.09.2026 11:00', 'working' => 'true' }
        ]
      }
    )
    allow(client).to receive(:get_receptions).and_return([])

    result = described_class.new(resource: resource, from: from_time, to: to_time, slots: slots, client: client).perform

    expect(result.status).to eq('fresh')
    expect(result.slots.size).to eq(2)
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

  it 'accepts persisted cabinet code key variants' do
    resource.update!(
      custom_attributes: resource.custom_attributes.merge(
        'medelement_cabinets' => [
          { 'company_cabinet_code' => 'cabinet-1' },
          { 'COMPANY_CABINET_CODE' => 'cabinet-2' }
        ]
      )
    )
    allow(client).to receive(:get_receptions).and_return([])

    result = described_class.new(
      resource: resource,
      from: from_time,
      to: to_time,
      slots: slots,
      client: client,
      cabinet_code: 'cabinet-2'
    ).perform

    expect(result).to have_attributes(status: 'fresh')
    expect(result.slots).to all(include(medelement_cabinet_code: 'cabinet-2'))
    expect(client).to have_received(:get_receptions).with(hash_including(company_cabinet_code: 'cabinet-2'))
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
