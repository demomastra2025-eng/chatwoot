require 'rails_helper'

RSpec.describe Reminders::MissedAutomationTouchPolicy do
  let(:now) { Time.zone.parse('2026-08-22 10:00') }
  let(:appointment) { Scheduling::Appointment.new(source: 'manual', starts_at: now + 1.hour, status: 'scheduled') }
  let(:metadata) { { 'touch_source' => 'automation' } }
  let(:scheduled_at) { now - 6.minutes }
  let(:reminder) do
    Reminder.new(
      status: 'processing',
      timing_mode: 'relative',
      relative_anchor: 'appointment.starts_at',
      relative_offset_seconds: -(1.hour + 6.minutes).to_i,
      scheduled_at: scheduled_at,
      metadata: metadata,
      remindable: appointment
    )
  end

  describe '#missed?' do
    it 'marks an appointment automation touch missed after the grace window regardless of source' do
      expect(described_class.new(reminder: reminder, now: now)).to be_missed
    end

    it 'keeps the touch eligible at the grace-window boundary' do
      reminder.scheduled_at = now - described_class::GRACE_WINDOW
      reminder.relative_offset_seconds = -(1.hour + described_class::GRACE_WINDOW).to_i

      expect(described_class.new(reminder: reminder, now: now)).not_to be_missed
    end

    it 'uses the live visit time when the stored time is stale after a later move' do
      appointment.starts_at = now + 2.hours

      expect(described_class.new(reminder: reminder, now: now)).not_to be_missed
    end

    it 'does not affect non-automation touches' do
      reminder.metadata = {}
      expect(described_class.new(reminder: reminder, now: now)).not_to be_missed
    end

    it 'skips a before-visit message after the appointment starts even within grace' do
      reminder.relative_offset_seconds = -1.minute.to_i
      reminder.scheduled_at = now - 1.minute
      appointment.starts_at = now

      expect(described_class.new(reminder: reminder, now: now).skip_reason).to eq(described_class::STARTED_REASON)
    end

    it 'keeps the late reason when a before-visit message is both overdue and past the visit start' do
      reminder.relative_offset_seconds = -2.hours.to_i
      appointment.starts_at = now - 1.hour

      expect(described_class.new(reminder: reminder, now: now).skip_reason).to eq(described_class::CANCEL_REASON)
    end

    it 'does not cancel a touch after delivery was materialized' do
      reminder.metadata = metadata.merge(Reminder::DELIVERY_MATERIALIZED_MESSAGE_ID_KEY => 123)

      expect(described_class.new(reminder: reminder, now: now)).not_to be_missed
    end
  end
end
