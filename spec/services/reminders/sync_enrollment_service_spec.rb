require 'rails_helper'

RSpec.describe Reminders::SyncEnrollmentService do
  let(:account) { create(:account) }
  let(:appointment) do
    create(
      :scheduling_appointment,
      account: account,
      starts_at: 2.days.from_now,
      ends_at: 2.days.from_now + 30.minutes
    )
  end
  let(:reminder_group) { create(:reminder_group, account: account) }
  let(:enrollment) do
    account.enable_features!('deferred_touch_materialization')
    Reminders::EnrollGroupService.new(
      account: account,
      reminder_group: reminder_group,
      remindable: appointment,
      actor: nil
    ).perform
  end

  it 'moves the next trigger when the appointment moves' do
    original_due_at = enrollment.next_due_at

    appointment.update!(starts_at: appointment.starts_at + 2.hours, ends_at: appointment.ends_at + 2.hours)

    expect(enrollment.reload.next_due_at).to be_within(2.seconds).of(original_due_at + 2.hours)
    expect(account.reminders.where(remindable: appointment)).to be_empty
  end

  it 'cancels the enrollment when the appointment is cancelled' do
    enrollment

    appointment.update!(status: 'cancelled')

    expect(enrollment.reload).to be_cancelled
  end

  it 'retains a cancelled audit enrollment after the appointment is destroyed' do
    enrollment

    appointment.destroy!

    expect(enrollment.reload).to be_cancelled
    expect(enrollment.remindable).to be_nil
  end

  it 'retains a cancelled audit enrollment after a deal is destroyed' do
    deal = create(:crm_deal, account: account, expected_close_on: 2.days.from_now.to_date)
    deal_group = create(
      :reminder_group,
      account: account,
      entity_kinds: ['deal'],
      touches: [
        {
          action_type: 'send_message',
          content_kind: 'free_text',
          text_mode: 'static',
          timing_mode: 'relative',
          relative_anchor: 'deal.expected_close_on',
          relative_offset_seconds: 0,
          timezone: 'UTC',
          body: 'Deal reminder'
        }
      ]
    )
    account.enable_features!('deferred_touch_materialization')
    deal_enrollment = Reminders::EnrollGroupService.new(
      account: account,
      reminder_group: deal_group,
      remindable: deal,
      actor: nil
    ).perform

    deal.destroy!

    expect(deal_enrollment.reload).to be_cancelled
    expect(deal_enrollment.remindable).to be_nil
  end
end
