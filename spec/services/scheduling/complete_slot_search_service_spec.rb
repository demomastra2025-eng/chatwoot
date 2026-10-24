require 'rails_helper'

# The complete search returns every free start of the range: the plain search stops at 100 starts (50 for a specialist on local
# hours), which ends one specialist's answer about eight hours into the first day.
RSpec.describe Scheduling::CompleteSlotSearchService do
  include ActiveSupport::Testing::TimeHelpers

  around { |example| travel_to(Time.utc(2026, 4, 19, 20)) { example.run } }

  let(:account) { create(:account) }
  let(:zone) { ActiveSupport::TimeZone['Asia/Almaty'] }
  let(:hook) { create(:integrations_hook, :medelement, account: account) }
  let(:resource) do
    create(:scheduling_resource, account: account, timezone: 'Asia/Almaty', slot_duration_min: 10, custom_attributes: {
             'medelement_specialist_code' => 'specialist-1', 'medelement_reception_time' => 10,
             'medelement_cabinets' => [{ 'companyCabinetCode' => 'cabinet-1' }]
           })
  end
  let(:local_resource) do
    create(:scheduling_resource, account: account, timezone: 'Asia/Almaty', slot_duration_min: 10).tap do |item|
      [1, 2].each do |weekday|
        create(:scheduling_work_rule, account: account, resource: item, weekday: weekday, start_minute: 8 * 60, end_minute: 20 * 60)
      end
    end
  end
  # Monday and Tuesday, 08:00-20:00: 72 starts a day for a visit of 10 minutes.
  let(:range) { { from: zone.local(2026, 4, 20), to: zone.local(2026, 4, 22), duration_min: 10 } }

  before do
    account.enable_features!('scheduling')
    hook
  end

  def store_day(date)
    windows = ((8 * 60)...(20 * 60)).step(10).map { |minute| { start_minute: minute, end_minute: minute + 10 } }
    Integrations::Medelement::ScheduleDay.create!(
      account: account, hook: hook, resource: resource, specialist_code: 'specialist-1', date: date,
      status: 'confirmed', source_checked_at: Time.current, windows: windows
    )
  end

  def search(klass, resource, **)
    klass.new(account: account, resource_ids: [resource.id], **range, **).perform
  end

  context 'with a MedElement specialist' do
    before { [Date.new(2026, 4, 20), Date.new(2026, 4, 21)].each { |date| store_day(date) } }

    it 'returns all the starts of both days where the plain search stops at 100' do
      capped = search(Scheduling::AvailableSlotSearchService, resource)
      complete = search(described_class, resource)

      expect(capped[:slots].size).to eq(100)
      expect(complete[:slots].size).to eq(144)
      expect(complete[:total_slots]).to eq(144)
      expect(complete[:slots].map { |slot| slot[:starts_at][0, 10] }.tally).to eq('2026-04-20' => 72, '2026-04-21' => 72)
      expect(complete[:slots].last[:starts_at]).to eq(zone.local(2026, 4, 21, 19, 50).iso8601)
    end

    it 'ignores the limit that is asked for' do
      expect(search(described_class, resource, limit: 5)[:slots].size).to eq(144)
    end

    it 'keeps the answer of the plain search for the rest of the payload' do
      plain = search(Scheduling::AvailableSlotSearchService, resource)
      complete = search(described_class, resource)

      expect(complete.except(:slots, :total_slots)).to eq(plain.except(:slots, :total_slots))
    end
  end

  context 'with a specialist on local hours' do
    it 'returns all the starts where the plain search stops at 50' do
      capped = search(Scheduling::AvailableSlotSearchService, local_resource)
      complete = search(described_class, local_resource)

      expect(capped[:slots].size).to eq(50)
      expect(complete[:slots].size).to eq(144)
    end
  end
end
