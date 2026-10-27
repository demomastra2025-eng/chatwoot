require 'rails_helper'

RSpec.describe Reminders::RetimeVisitTouchesService do
  let(:account) { create(:account) }
  let(:conversation) { create(:conversation, account: account) }
  let(:appointment) do
    create(:scheduling_appointment, account: account, contact: conversation.contact, conversation: conversation,
                                    starts_at: 2.days.from_now, ends_at: 2.days.from_now + 30.minutes)
  end

  def visit_touch(offset: -2.hours.to_i, anchor: 'appointment.starts_at', **attributes)
    create(
      :reminder, account: account, remindable: appointment, touch_conversation: conversation, timing_mode: 'relative',
                 relative_anchor: anchor, relative_offset_seconds: offset, scheduled_at: nil,
                 metadata: { 'touch_source' => 'automation' }, **attributes
    )
  end

  it 'moves an open reminder earlier and later with the visit' do
    touch = visit_touch
    earlier = appointment.starts_at - 3.hours
    appointment.update!(starts_at: earlier, ends_at: earlier + 30.minutes)
    expect(touch.reload.scheduled_at.to_i).to eq((earlier - 2.hours).to_i)

    later = appointment.starts_at + 1.day
    appointment.update!(starts_at: later, ends_at: later + 30.minutes)
    expect(touch.reload.scheduled_at.to_i).to eq((later - 2.hours).to_i)
  end

  it 'uses the reminder timezone for a day-before fixed time after a date change' do
    zone = Time.find_zone!('Asia/Almaty')
    touch = visit_touch(
      offset: -1.day.to_i, relative_time_mode: 'fixed_time_of_day', relative_time_of_day: '15:00', timezone: zone.name
    )
    moved = appointment.starts_at + 1.day
    appointment.update!(starts_at: moved, ends_at: moved + 30.minutes)
    expect(touch.reload.scheduled_at.to_i).to eq(zone.parse("#{moved.in_time_zone(zone).to_date - 1} 15:00").to_i)
  end

  it 'cancels a reminder when the visit starts or its new due time missed grace' do
    touch = visit_touch
    moved = 30.minutes.from_now
    appointment.update!(starts_at: moved, ends_at: moved + 30.minutes)
    expect(touch.reload).to be_cancelled
    expect(touch.last_error).to eq(Reminders::MissedAutomationTouchPolicy::CANCEL_REASON)
  end

  it 'keeps a reminder pending when its new due time is within grace' do
    touch = visit_touch
    moved = 2.hours.from_now - 3.minutes
    appointment.update!(starts_at: moved, ends_at: moved + 30.minutes)

    expect(touch.reload).to be_pending
    expect(touch.scheduled_at.to_i).to eq((moved - 2.hours).to_i)
  end

  %w[completed no_show cancelled].each do |status|
    it "closes a before-visit reminder for #{status}, preserving an after-visit follow-up" do
      before_visit = visit_touch
      follow_up = visit_touch(offset: 1.hour.to_i, anchor: 'appointment.ends_at')
      appointment.update!(status: status)
      expect(before_visit.reload).to be_cancelled
      expect(before_visit.last_error).to eq(Reminders::MissedAutomationTouchPolicy::CLOSED_REASON)
      expect(follow_up.reload).to be_pending
    end
  end

  it 'preserves an event-moment cancellation notice when the visit is cancelled' do
    notice = visit_touch(offset: 1.minute.to_i, anchor: 'appointment.created_at', body: 'Cancellation notice')

    appointment.update!(status: 'cancelled')

    expect(notice.reload).to be_pending
  end

  it 'does not refresh a running visit during MedElement reconciliation' do
    touch = visit_touch
    original = touch.scheduled_at
    Current.medelement_reconciliation = true
    moved = appointment.starts_at + 1.day
    appointment.update!(starts_at: moved, ends_at: moved + 30.minutes)
    expect(touch.reload.scheduled_at).to eq(original)
  ensure
    Current.medelement_reconciliation = false
  end

  it 'still closes before-visit reminders for terminal MedElement reconciliation' do
    touch = visit_touch
    Current.medelement_reconciliation = true
    appointment.update!(status: 'completed')

    expect(touch.reload).to be_cancelled
  ensure
    Current.medelement_reconciliation = false
  end

  it 'continues with another reminder when one reminder cannot be saved' do
    broken = visit_touch(body: 'First notification')
    healthy = visit_touch(body: 'Second notification')
    broken.class.connection.execute("UPDATE reminders SET timezone = 'Invalid/Zone' WHERE id = #{Integer(broken.id)}")
    moved = appointment.starts_at + 1.day

    appointment.update!(starts_at: moved, ends_at: moved + 30.minutes)

    expect(healthy.reload.scheduled_at.to_i).to eq((moved - 2.hours).to_i)
    expect(broken.reload.scheduled_at.to_i).not_to eq((moved - 2.hours).to_i)
  end

  it 're-times a materialized deferred reminder and preserves its claim' do
    touch = visit_touch(body: 'Deferred notification')
    enrollment = create(:touch_plan_enrollment, account: account, remindable: appointment)
    claim = create(:touch_occurrence_claim, account: account, touch_plan_enrollment: enrollment,
                                            reminder: touch, status: 'materialized')
    touch.update!(metadata: touch.metadata.merge('touch_plan_enrollment_id' => enrollment.id,
                                                 'touch_occurrence_claim_id' => claim.id))
    moved = appointment.starts_at + 1.day

    appointment.update!(starts_at: moved, ends_at: moved + 30.minutes)

    expect(touch.reload.scheduled_at.to_i).to eq((moved - 2.hours).to_i)
    expect(claim.reload).to be_materialized
  end
end
