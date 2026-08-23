require 'rails_helper'

RSpec.describe Reminders::MissedAutomationTouchPolicy do
  let(:now) { Time.zone.parse('2026-08-22 10:00') }
  let(:appointment) { Scheduling::Appointment.new(source: 'medelement') }
  let(:metadata) { { 'touch_source' => 'automation' } }
  let(:scheduled_at) { now - 6.minutes }
  let(:reminder) do
    Reminder.new(
      status: 'processing',
      timing_mode: 'relative',
      relative_anchor: 'appointment.starts_at',
      scheduled_at: scheduled_at,
      metadata: metadata,
      remindable: appointment
    )
  end

  describe '#missed?' do
    it 'marks a MedElement appointment automation touch missed after the grace window' do
      expect(described_class.new(reminder: reminder, now: now)).to be_missed
    end

    it 'keeps the touch eligible at the grace-window boundary' do
      reminder.scheduled_at = now - described_class::GRACE_WINDOW

      expect(described_class.new(reminder: reminder, now: now)).not_to be_missed
    end

    it 'does not affect manual appointments or non-automation touches' do
      appointment.source = 'manual'
      expect(described_class.new(reminder: reminder, now: now)).not_to be_missed

      appointment.source = 'medelement'
      reminder.metadata = {}
      expect(described_class.new(reminder: reminder, now: now)).not_to be_missed
    end

    it 'does not cancel a touch after delivery was materialized' do
      reminder.metadata = metadata.merge(Reminder::DELIVERY_MATERIALIZED_MESSAGE_ID_KEY => 123)

      expect(described_class.new(reminder: reminder, now: now)).not_to be_missed
    end
  end
end
