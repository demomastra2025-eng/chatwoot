require 'rails_helper'

RSpec.describe Scheduling::Appointment do
  it 'recomputes automation reminders after a resource change through the model callback' do
    account = create(:account)
    conversation = create(:conversation, account: account)
    appointment = create(:scheduling_appointment, account: account, contact: conversation.contact,
                                                  conversation: conversation, starts_at: 2.days.from_now,
                                                  ends_at: 2.days.from_now + 30.minutes)
    touch = create(:reminder, account: account, remindable: appointment, touch_conversation: conversation, timing_mode: 'relative',
                              relative_anchor: 'appointment.starts_at', relative_offset_seconds: -1.hour.to_i,
                              scheduled_at: nil, metadata: { 'touch_source' => 'automation' })
    resource = create(:scheduling_resource, account: account)

    appointment.update!(resource: resource)

    expect(touch.reload.scheduled_at.to_i).to eq((appointment.starts_at - 1.hour).to_i)
    expect(touch).to be_pending
  end
end
