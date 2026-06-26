require 'rails_helper'

RSpec.describe Reminders::SyncRemindableService do
  describe '#perform' do
    it 'recalculates open relative appointment touches while keeping the fixed time of day' do
      zone = Time.find_zone!('Asia/Almaty')
      appointment = create(
        :scheduling_appointment,
        starts_at: zone.parse('2026-07-10 15:00'),
        ends_at: zone.parse('2026-07-10 15:30')
      )
      touch = create(
        :reminder,
        account: appointment.account,
        remindable: appointment,
        timing_mode: :relative,
        relative_anchor: 'appointment.starts_at',
        relative_offset_seconds: -1.day.to_i,
        relative_time_mode: 'fixed_time_of_day',
        relative_time_of_day: '10:00',
        timezone: 'Asia/Almaty',
        scheduled_at: nil,
        body: 'Rescheduled appointment touch'
      )

      appointment.update!(
        starts_at: zone.parse('2026-07-12 18:00'),
        ends_at: zone.parse('2026-07-12 18:30')
      )

      described_class.new(remindable: appointment).perform

      expect(touch.reload.scheduled_at.to_i).to eq(zone.parse('2026-07-11 10:00').to_i)
      expect(touch.last_materialized_anchor_at.to_i).to eq(appointment.starts_at.to_i)
      expect(touch.schedule_revision).to be >= 2
    end

    it 'does not recalculate manually overridden relative touches' do
      zone = Time.find_zone!('Asia/Almaty')
      appointment = create(
        :scheduling_appointment,
        starts_at: zone.parse('2026-07-10 15:00'),
        ends_at: zone.parse('2026-07-10 15:30')
      )
      manual_scheduled_at = zone.parse('2026-07-15 12:00')
      touch = create(
        :reminder,
        account: appointment.account,
        remindable: appointment,
        timing_mode: :relative,
        relative_anchor: 'appointment.starts_at',
        relative_offset_seconds: -1.day.to_i,
        relative_time_mode: 'fixed_time_of_day',
        relative_time_of_day: '10:00',
        manual_schedule_override: true,
        scheduled_at: manual_scheduled_at,
        body: 'Manual appointment touch'
      )

      appointment.update!(
        starts_at: zone.parse('2026-07-12 18:00'),
        ends_at: zone.parse('2026-07-12 18:30')
      )

      described_class.new(remindable: appointment).perform

      expect(touch.reload.scheduled_at.to_i).to eq(manual_scheduled_at.to_i)
      expect(touch.last_materialized_anchor_at).to be_nil
    end
  end
end
