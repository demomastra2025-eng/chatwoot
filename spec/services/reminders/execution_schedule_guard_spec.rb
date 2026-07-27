require 'rails_helper'

RSpec.describe Reminders::ExecutionScheduleGuard do
  let(:zone) { Time.find_zone!('Asia/Almaty') }

  def appointment_at(starts_at)
    create(
      :scheduling_appointment,
      starts_at: starts_at,
      ends_at: starts_at + 30.minutes
    )
  end

  def appointment_touch(appointment)
    create(
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
      body: 'Appointment touch'
    )
  end

  it 'cancels a relative touch whose scheduled time passed before creation' do
    appointment = appointment_at((zone.now - 10.days).change(hour: 15, min: 0, sec: 0))
    touch = appointment_touch(appointment)
    touch.mark_processing!

    result = described_class.new(reminder: touch).perform

    expect(result).to eq(described_class::STOP)
    expect(touch.reload).to be_cancelled
    expect(touch.last_error).to eq(described_class::MISSED_RELATIVE_SCHEDULE)
  end

  it 'reschedules a processing touch when the appointment moved before materialization' do
    initial_start = (3.days.from_now.in_time_zone(zone)).change(hour: 15, min: 0, sec: 0)
    moved_start = initial_start + 2.days
    appointment = appointment_at(initial_start)
    touch = appointment_touch(appointment)
    touch.mark_processing!

    appointment.update!(
      starts_at: moved_start,
      ends_at: moved_start + 30.minutes
    )

    result = described_class.new(reminder: touch).perform

    expect(result).to eq(described_class::STOP)
    expect(touch.reload).to be_pending
    expect(touch.scheduled_at.to_i).to eq(zone.parse("#{moved_start.to_date - 1} 10:00").to_i)
    expect(touch.last_materialized_anchor_at.to_i).to eq(moved_start.to_i)
  end

  it 'cancels a claimed deferred touch when its enrollment was cancelled' do
    appointment = appointment_at(2.days.from_now)
    enrollment = create(:touch_plan_enrollment, account: appointment.account, remindable: appointment)
    touch = appointment_touch(appointment)
    claim = create(
      :touch_occurrence_claim,
      account: appointment.account,
      touch_plan_enrollment: enrollment,
      reminder: touch,
      status: 'materialized'
    )
    touch.update!(
      metadata: {
        'touch_plan_enrollment_id' => enrollment.id,
        'touch_occurrence_claim_id' => claim.id
      }
    )
    touch.mark_processing!
    enrollment.cancel!(reason: 'test')

    result = described_class.new(reminder: touch).perform

    expect(result).to eq(described_class::STOP)
    expect(touch.reload).to be_cancelled
    expect(claim.reload).to be_skipped
  end
end
