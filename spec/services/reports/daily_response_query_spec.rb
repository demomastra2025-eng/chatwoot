require 'rails_helper'

RSpec.describe Reports::DailyResponseQuery do
  let(:account) { create(:account, settings: { 'timezone' => 'Asia/Almaty' }) }
  let(:inbox) { create(:inbox, account: account) }
  let(:contact) { create(:contact, account: account) }

  describe '#perform' do
    it 'calculates daily totals, same-day answered counts, and average response/wait times' do
      day_one = Time.find_zone('Asia/Almaty').local(2026, 4, 10, 11, 0, 0)
      day_two = Time.find_zone('Asia/Almaty').local(2026, 4, 11, 14, 0, 0)

      conv_answered = travel_to(day_one) do
        create(:conversation, account: account, inbox: inbox, contact: contact)
      end
      travel_to(day_one + 5.minutes) do
        create(:conversation, account: account, inbox: inbox, contact: contact)
      end

      ReportingEvent.create!(
        account: account,
        inbox: inbox,
        conversation: conv_answered,
        name: 'first_response',
        value: 180,
        event_start_time: day_one,
        event_end_time: day_one + 3.minutes,
        created_at: day_one + 3.minutes,
        updated_at: day_one + 3.minutes
      )

      ReportingEvent.create!(
        account: account,
        inbox: inbox,
        conversation: conv_answered,
        name: 'reply_time',
        value: 420,
        event_start_time: day_one + 10.minutes,
        event_end_time: day_one + 17.minutes,
        created_at: day_one + 17.minutes,
        updated_at: day_one + 17.minutes
      )

      travel_to(day_two) do
        create(:conversation, account: account, inbox: inbox, contact: contact)
      end

      result = described_class.new(
        account: account,
        params: { from_date: '2026-04-10', to_date: '2026-04-11' }
      ).perform

      expect(result[:summary]).to eq(
        days: 2,
        total: 3,
        answered: 1,
        unanswered: 2,
        answered_share_percent: 33.3,
        avg_first_response_seconds: 180,
        avg_reply_wait_seconds: 420
      )

      expect(result[:rows].size).to eq(2)
      first_row = result[:rows].first
      expect(first_row[:date]).to eq('2026-04-10')
      expect(first_row[:total]).to eq(2)
      expect(first_row[:answered]).to eq(1)
      expect(first_row[:unanswered]).to eq(1)
      expect(first_row[:answered_share_percent]).to eq(50.0)
      expect(first_row[:avg_first_response_seconds]).to eq(180)
      expect(first_row[:avg_reply_wait_seconds]).to eq(420)
    end
  end
end
