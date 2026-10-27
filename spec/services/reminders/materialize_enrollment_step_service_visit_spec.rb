require 'rails_helper'

RSpec.describe Reminders::MaterializeEnrollmentStepService do
  it 'skips a deferred step after the visit moves earlier beyond the shared grace window' do
    account = create(:account).tap { |record| record.enable_features!('deferred_touch_materialization') }
    starts_at = 2.days.from_now
    appointment = create(:scheduling_appointment, account: account, starts_at: starts_at,
                                                  ends_at: starts_at + 30.minutes)
    inbox = create(:inbox, account: account)
    group = create(:reminder_group, account: account, entity_kinds: ['appointment'], touches: [
                     attributes_for(:reminder).slice(:body).merge(entity_kind: 'appointment', timing_mode: 'relative',
                                                                  relative_anchor: 'appointment.starts_at', relative_offset_seconds: -2.hours.to_i,
                                                                  target_inbox_id: inbox.id, timezone: 'UTC')
                   ])
    enrollment = Reminders::EnrollGroupService.new(account: account, reminder_group: group,
                                                   remindable: appointment, actor: nil).perform
    moved = 1.hour.from_now
    appointment.update!(starts_at: moved, ends_at: moved + 30.minutes)

    claim = described_class.new(enrollment: enrollment.reload, now: Time.current).perform

    expect(claim).to have_attributes(status: 'skipped', last_error: 'missed_due_to_reschedule')
    expect(account.reminders.where(remindable: appointment)).to be_empty
  end
end
