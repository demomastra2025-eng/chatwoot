require 'rails_helper'

RSpec.describe Captain::Tools::Copilot::GetSchedulingResourceScheduleService do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:service) { described_class.new(assistant, user: user) }
  let(:resource) { create(:scheduling_resource, account: account, name: 'Aigerim', timezone: 'Asia/Almaty') }
  let(:monday) { Time.zone.parse('2026-04-20 00:00:00') }
  let(:tuesday) { monday + 1.day }

  before do
    account.enable_features!('scheduling')
    create(:scheduling_work_rule, resource: resource, weekday: 1, start_minute: 9 * 60, end_minute: 18 * 60)
    create(:scheduling_break_rule, resource: resource, weekday: 1, start_minute: 13 * 60, end_minute: 14 * 60, title: 'Lunch')
  end

  describe '#execute' do
    it 'returns normalized schedule days with working windows and breaks' do
      payload = JSON.parse(service.execute(resource_id: resource.id, from: monday.iso8601, to: tuesday.iso8601))

      expect(payload['resource']['id']).to eq(resource.id)
      expect(payload['days'].first['date']).to eq('2026-04-20')
      expect(payload['days'].first['working']).to be(true)
      expect(payload['days'].first['windows']).to eq([
                                                       {
                                                         'start_at' => '2026-04-20T09:00:00+05:00',
                                                         'end_at' => '2026-04-20T18:00:00+05:00'
                                                       }
                                                     ])
      expect(payload['days'].first['breaks']).to eq([
                                                      {
                                                        'start_at' => '2026-04-20T13:00:00+05:00',
                                                        'end_at' => '2026-04-20T14:00:00+05:00',
                                                        'title' => 'Lunch'
                                                      }
                                                    ])
    end

    it 'marks holidays as non-working unless an override exists' do
      create(:scheduling_holiday, account: account, date: monday.to_date, title: 'Holiday')

      payload = JSON.parse(service.execute(resource_id: resource.id, from: monday.iso8601, to: tuesday.iso8601))

      expect(payload['days'].first['working']).to be(false)
      expect(payload['days'].first['source']).to eq('holiday')
    end

    it 'prefers workday overrides over the weekly schedule' do
      create(:scheduling_holiday, account: account, date: monday.to_date, title: 'Holiday')
      create(
        :scheduling_workday_override,
        resource: resource,
        date: monday.to_date,
        start_minute: 10 * 60,
        end_minute: 16 * 60,
        break_start_minute: 12 * 60,
        break_end_minute: 13 * 60
      )

      payload = JSON.parse(service.execute(resource_id: resource.id, from: monday.iso8601, to: tuesday.iso8601))

      expect(payload['days'].first['working']).to be(true)
      expect(payload['days'].first['source']).to eq('override')
      expect(payload['days'].first['windows']).to eq([
                                                       {
                                                         'start_at' => '2026-04-20T10:00:00+05:00',
                                                         'end_at' => '2026-04-20T16:00:00+05:00'
                                                       }
                                                     ])
    end
  end
end
