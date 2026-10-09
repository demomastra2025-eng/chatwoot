require 'rails_helper'

RSpec.describe Scheduling::CalendarViewService do
  include ActiveSupport::Testing::TimeHelpers

  let(:account) { create(:account) }
  let(:base_options) do
    {
      account: account,
      view: 'day',
      from: Time.zone.parse('2026-09-14 09:00:00'),
      to: Time.zone.parse('2026-09-14 18:00:00')
    }
  end

  it 'rejects malformed resource IDs at the service boundary' do
    ['abc', 42, { id: 42 }, [[42]], true].each do |value|
      expect do
        described_class.new(**base_options, resource_ids: value)
      end.to raise_error(ArgumentError, /resource_ids must contain positive integer IDs/)
    end
  end

  it 'normalizes valid resource IDs before querying the account scope' do
    first_resource = create(:scheduling_resource, account: account)
    second_resource = create(:scheduling_resource, account: account)

    result = described_class.new(**base_options, resource_ids: "#{first_resource.id},#{second_resource.id}").perform

    expect(result.fetch(:resources).map(&:id)).to contain_exactly(first_resource.id, second_resource.id)
  end

  it 'uses live provider windows for an integrated specialist while local holidays still block other specialists' do
    travel_to(Time.utc(2026, 9, 13, 12)) do
      account.enable_features!('scheduling')
      create(:integrations_hook, :medelement, account: account)
      provider = create(
        :scheduling_resource,
        account: account,
        timezone: 'Asia/Almaty',
        custom_attributes: {
          'medelement_specialist_code' => 'doctor-1',
          'medelement_cabinets' => [{ 'companyCabinetCode' => 'cabinet-1' }]
        }
      )
      local = create(:scheduling_resource, account: account, timezone: 'Asia/Almaty')
      create(:scheduling_work_rule, account: account, resource: local, weekday: 1)
      create(:scheduling_holiday, account: account, date: Date.new(2026, 9, 14))
      client = instance_double(Integrations::Medelement::Client)
      allow(Integrations::Medelement::Client).to receive(:new).and_return(client)
      allow(client).to receive(:timetable).and_return(
        '14.09.2026' => { 'timetable' => [
          { 'start' => '14.09.2026 09:00', 'end' => '14.09.2026 11:00', 'working' => true }
        ] }
      )
      allow(client).to receive(:get_receptions).and_return([])
      zone = ActiveSupport::TimeZone['Asia/Almaty']

      payload = described_class.new(account: account, view: 'day',
                                    from: zone.local(2026, 9, 14, 9), to: zone.local(2026, 9, 14, 11),
                                    resource_ids: [provider.id, local.id], include_slots: true).perform

      expect(payload[:slots].pluck(:resource_id)).to include(provider.id)
      expect(payload[:slots].pluck(:resource_id)).not_to include(local.id)
      expect(client).to have_received(:timetable).once
    end
  end

  it 'does not ask MedElement for calendar slots beyond its horizon' do
    resource = create(
      :scheduling_resource,
      account: account,
      custom_attributes: { 'medelement_specialist_code' => 'doctor-1' }
    )
    zone = ActiveSupport::TimeZone['Asia/Almaty']
    date = zone.today + 90
    from = zone.local(date.year, date.month, date.day, 9)
    expect(Integrations::Medelement::ResourceAvailabilityService).not_to receive(:new)

    payload = described_class.new(account: account, view: 'day', from: from, to: from + 2.hours,
                                  resource_ids: [resource.id], include_slots: true).perform

    expect(payload[:slots]).to be_empty
  end
end
