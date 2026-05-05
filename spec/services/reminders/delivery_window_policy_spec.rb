require 'rails_helper'

RSpec.describe Reminders::DeliveryWindowPolicy do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account, timezone: 'UTC', working_hours_enabled: true) }
  let(:contact) { create(:contact, account: account) }
  let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: inbox) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox) }
  let(:reminder) do
    create(
      :reminder,
      account: account,
      touch_conversation: conversation,
      conversation: conversation,
      remindable: conversation,
      status: :processing,
      body: 'Respect working hours'
    )
  end

  describe '#call' do
    it 'allows delivery when inbox working hours are disabled' do
      inbox.update!(working_hours_enabled: false)

      result = described_class.new(reminder: reminder, conversation: conversation, now: Time.zone.parse('2026-05-02 23:00:00 UTC')).call

      expect(result).to be_allowed
    end

    it 'allows delivery inside a configured working window' do
      result = described_class.new(reminder: reminder, conversation: conversation, now: Time.zone.parse('2026-05-04 10:00:00 UTC')).call

      expect(result).to be_allowed
    end

    it 'reschedules before opening into the first 30 minutes of the same day window' do
      result = described_class.new(reminder: reminder, conversation: conversation, now: Time.zone.parse('2026-05-04 08:00:00 UTC')).call

      expect(result).to be_blocked
      expect(result.scheduled_at).to be_between(
        Time.zone.parse('2026-05-04 09:00:00 UTC'),
        Time.zone.parse('2026-05-04 09:30:00 UTC')
      ).inclusive
    end

    it 'reschedules weekend touches into the first 30 minutes of the nearest next working window deterministically' do
      now = Time.zone.parse('2026-05-02 23:00:00 UTC')

      first_result = described_class.new(reminder: reminder, conversation: conversation, now: now).call
      second_result = described_class.new(reminder: reminder, conversation: conversation, now: now).call

      expect(first_result).to be_blocked
      expect(first_result.scheduled_at).to be_between(
        Time.zone.parse('2026-05-04 09:00:00 UTC'),
        Time.zone.parse('2026-05-04 09:30:00 UTC')
      ).inclusive
      expect(second_result.scheduled_at).to eq(first_result.scheduled_at)
    end

    it 'treats an open-all-day schedule as 24x7 for that day' do
      inbox.working_hours.find_by(day_of_week: 6).update!(open_all_day: true, closed_all_day: false)

      result = described_class.new(reminder: reminder, conversation: conversation, now: Time.zone.parse('2026-05-02 23:00:00 UTC')).call

      expect(result).to be_allowed
    end
  end

  describe '.apply!' do
    it 'keeps the reminder pending and stores audit metadata when rescheduled' do
      travel_to(Time.zone.parse('2026-05-02 23:00:00 UTC')) do
        result = described_class.apply!(reminder: reminder, conversation: conversation)

        reminder.reload
        expect(result).to be_blocked
        expect(reminder).to be_pending
        expect(reminder.processing_started_at).to be_nil
        expect(reminder.last_error).to be_nil
        expect(reminder.metadata).to include(
          'rescheduled_by_working_hours' => true,
          'working_hours_reschedule_reason' => 'outside_working_hours',
          'working_hours_target_inbox_id' => inbox.id
        )
      end
    end
  end
end
