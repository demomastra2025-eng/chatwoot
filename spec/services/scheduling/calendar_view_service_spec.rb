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

  it 'uses stored provider windows for an integrated specialist while local holidays still block other specialists' do
    travel_to(Time.utc(2026, 9, 13, 12)) do
      account.enable_features!('scheduling')
      hook = create(:integrations_hook, :medelement, account: account)
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
      Integrations::Medelement::ScheduleDay.create!(
        account: account, hook: hook, resource: provider, specialist_code: 'doctor-1',
        date: Date.new(2026, 9, 14), status: 'confirmed', source_checked_at: Time.current,
        windows: [{ start_minute: 9 * 60, end_minute: 11 * 60 }]
      )
      expect(Integrations::Medelement::Client).not_to receive(:new)
      zone = ActiveSupport::TimeZone['Asia/Almaty']

      payload = described_class.new(account: account, view: 'day',
                                    from: zone.local(2026, 9, 14, 9), to: zone.local(2026, 9, 14, 11),
                                    resource_ids: [provider.id, local.id], include_slots: true).perform

      expect(payload[:slots].pluck(:resource_id)).to include(provider.id)
      expect(payload[:slots].pluck(:resource_id)).not_to include(local.id)
    end
  end

  it 'retains appointments for 32 integrated specialists on a past day without fetching provider availability' do
    travel_to(Time.utc(2026, 10, 10, 3)) do
      account.enable_features!('scheduling')
      create(:integrations_hook, :medelement, account: account)
      zone = ActiveSupport::TimeZone['Asia/Almaty']
      from = zone.local(2026, 10, 5)
      resources = Array.new(32) do |index|
        create(:scheduling_resource, account: account, timezone: 'Asia/Almaty',
                                     custom_attributes: {
                                       'medelement_specialist_code' => "doctor-#{index}",
                                       'medelement_cabinets' => [{ 'companyCabinetCode' => 'cabinet-1' }]
                                     })
      end
      contact = create(:contact, account: account)
      appointments = resources.map do |resource|
        create(:scheduling_appointment, account: account, resource: resource, contact: contact, service: nil,
                                        starts_at: from + 10.hours, ends_at: from + 10.hours + 30.minutes)
      end
      create(:scheduling_work_rule, account: account, resource: resources.first, weekday: from.wday)
      expect(Integrations::Medelement::ResourceAvailabilityService).not_to receive(:new)
      expect(Integrations::Medelement::Client).not_to receive(:new)

      payload = Scheduling::PayloadBuilder.calendar(
        described_class.new(account: account, view: 'day', from: from, to: from + 1.day,
                            resource_ids: resources.map(&:id), include_slots: true).perform
      )

      expect(payload[:resources].pluck(:id)).to match_array(resources.map(&:id))
      expect(payload[:appointments].pluck(:id)).to match_array(appointments.map(&:id))
      expect(payload[:slots]).to be_empty
    end
  end

  it 'does not fetch live MedElement slots for an eligible specialist beyond the background cache' do
    account.enable_features!('scheduling')
    create(:integrations_hook, :medelement, account: account)
    resource = create(
      :scheduling_resource,
      account: account,
      custom_attributes: {
        'medelement_specialist_code' => 'doctor-1',
        'medelement_cabinets' => [{ 'companyCabinetCode' => 'cabinet-1' }]
      }
    )
    zone = ActiveSupport::TimeZone['Asia/Almaty']
    date = zone.today + 90
    from = zone.local(date.year, date.month, date.day, 9)
    expect(Integrations::Medelement::ResourceAvailabilityService).not_to receive(:new)
    expect(Integrations::Medelement::Client).not_to receive(:new)

    payload = described_class.new(account: account, view: 'day', from: from, to: from + 2.hours,
                                  resource_ids: [resource.id], include_slots: true).perform

    expect(payload[:slots]).to be_empty
  end
end
