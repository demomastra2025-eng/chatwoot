require 'rails_helper'

RSpec.describe Reminders::ExecutionScheduleGuard do
  it 'cancels the 2-hour reminder when the visit moves earlier after the reminder was claimed' do
    account = create(:account)
    start = 3.hours.from_now
    appointment = create(:scheduling_appointment, account: account, starts_at: start, ends_at: start + 30.minutes)
    touch = create(
      :reminder, account: account, remindable: appointment, timing_mode: 'relative',
                 relative_anchor: 'appointment.starts_at', relative_offset_seconds: -2.hours.to_i,
                 scheduled_at: nil, metadata: { 'touch_source' => 'automation' }
    )
    touch.mark_processing!
    allow(Reminders::RetimeVisitTouchesService).to receive(:new).and_return(instance_double(Reminders::RetimeVisitTouchesService, perform: nil))
    moved = 1.hour.ago
    appointment.update!(starts_at: moved, ends_at: moved + 30.minutes)

    expect(described_class.new(reminder: touch.reload).perform).to eq(described_class::STOP)
    expect(touch.reload).to be_cancelled
    expect(touch.last_error).to eq(Reminders::MissedAutomationTouchPolicy::STARTED_REASON)
  end
end
