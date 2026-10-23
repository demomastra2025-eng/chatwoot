require 'rails_helper'

RSpec.describe Reminders::DeferredAutomationActionPolicy do
  let(:account) { create(:account) }
  let(:appointment) { Scheduling::Appointment.new(account: account) }
  let(:after_event) { { body: 'Запись перенесена', timing_mode: 'relative', relative_anchor: 'touch.created_at', relative_offset_seconds: 60 } }

  before { account.enable_features!('deferred_touch_materialization') }

  def eligible?(definition, event_name: nil)
    described_class.new(account: account, remindable: appointment, definition: definition, event_name: event_name).eligible?
  end

  it 'still defers a touch timed from a booking, which fires once per appointment' do
    expect(eligible?(after_event, event_name: 'appointment_created')).to be(true)
    expect(eligible?(after_event)).to be(true)
  end

  it 'makes a touch timed from a reschedule at once so every reschedule notifies' do
    expect(eligible?(after_event, event_name: 'appointment_rescheduled')).to be(false)
    expect(eligible?({ body: 'Запись перенесена', delay_minutes: 0 }, event_name: 'appointment_rescheduled')).to be(false)
  end

  it 'keeps deferring the touches of every other event' do
    expect(eligible?(after_event, event_name: 'appointment_updated')).to be(true)
    expect(eligible?(after_event, event_name: 'appointment_cancelled')).to be(true)
    expect(eligible?({ body: 'Запись отменена', delay_minutes: 0 }, event_name: 'appointment_updated')).to be(true)
  end

  it 'keeps deferring a visit-timed touch of a repeating event, which follows the appointment' do
    visit_timed = after_event.merge(relative_anchor: 'appointment.starts_at', relative_offset_seconds: -2.hours.to_i)

    expect(eligible?(visit_timed, event_name: 'appointment_rescheduled')).to be(true)
    expect(eligible?(after_event.merge(relative_anchor: 'appointment.created_at'), event_name: 'appointment_rescheduled')).to be(true)
  end

  it 'never defers a touch that still carries the manual-time flag' do
    expect(eligible?(after_event.merge(manual_schedule_override: true), event_name: 'appointment_created')).to be(false)
  end
end
