require 'rails_helper'

RSpec.describe AutomationRules::AppointmentMovedToAnotherDayService do
  include ActiveJob::TestHelper

  let(:account) do
    create(:account).tap { |record| record.enable_features!('scheduling', 'deferred_touch_materialization') }
  end
  let(:channel) do
    create(:channel_whatsapp, account: account, provider: 'whatsapp_cloud', sync_templates: false, validate_provider_config: false)
  end
  let(:contact) { create(:contact, account: account, name: 'Jane Patient', phone_number: '+77000000011') }
  let(:conversation) do
    create(:conversation, account: account, inbox: channel.inbox, contact: contact,
                          contact_inbox: create(:contact_inbox, contact: contact, inbox: channel.inbox, source_id: '77000000011'))
  end
  let(:resource) { create(:scheduling_resource, account: account, timezone: 'Asia/Almaty') }
  let(:starts_at) { Time.utc(2026, 11, 20, 10, 30) } # 15:30 on 20.11 in Almaty
  let(:appointment) do
    create(:scheduling_appointment, account: account, resource: resource, contact: contact, conversation: conversation,
                                    status: 'confirmed', starts_at: starts_at, ends_at: starts_at + 30.minutes)
  end
  let(:confirmation_action_id) { SecureRandom.uuid }
  let(:two_hours_action_id) { SecureRandom.uuid }
  let(:notice_action_id) { SecureRandom.uuid }
  let(:rule) do
    create(
      :automation_rule,
      account: account,
      event_name: 'appointment_created',
      conditions: [{ attribute_key: 'status', filter_operator: 'equal_to', values: %w[scheduled confirmed], query_operator: nil }],
      actions: [
        { action_name: 'send_webhook_event', action_params: ['https://example.com/hooks/appointments'] },
        { action_name: 'create_touch', action_id: confirmation_action_id, action_params: [{
          content_kind: 'channel_template', target_inbox_id: channel.inbox.id,
          template_params: { name: 'appointment_confirmation', language: 'ru' },
          response_action: 'confirm_appointment', response_button_index: 0,
          timing_mode: 'relative', relative_anchor: 'appointment.starts_at', relative_offset_seconds: -1.day.to_i,
          relative_time_mode: 'fixed_time_of_day', relative_time_of_day: '15:00', timezone: 'Asia/Almaty'
        }] },
        { action_name: 'create_touch', action_id: two_hours_action_id, action_params: [{
          body: 'Reminder in two hours', timing_mode: 'relative', relative_anchor: 'appointment.starts_at',
          relative_offset_seconds: -2.hours.to_i, relative_time_mode: 'inherit_anchor_time', timezone: 'Asia/Almaty'
        }] },
        { action_name: 'create_touch', action_id: notice_action_id, action_params: [{
          body: 'Your visit is booked', timing_mode: 'relative', relative_anchor: 'touch.created_at',
          relative_offset_seconds: 60, relative_time_mode: 'inherit_anchor_time', timezone: 'Asia/Almaty'
        }] }
      ]
    )
  end

  def automation_touches(action_id)
    account.reminders.where(remindable: appointment).where('metadata @> ?', { 'automation_action_key' => action_id }.to_json).order(:id)
  end

  def two_hour_enrollments
    account.touch_plan_enrollments.where(remindable: appointment, source_action_id: two_hours_action_id).order(:id)
  end

  def plan_the_booking
    AutomationRules::AppointmentActionService.new(rule, account, appointment).perform(raise_errors: true)
  end

  # What has gone out for the old date: the confirmation question, and the deferred two-hour reminder materialized and sent.
  def deliver_for_the_old_date
    touch = automation_touches(confirmation_action_id).first
    touch.update_columns(status: Reminder.statuses[:completed], completed_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
    enrollment = two_hour_enrollments.first
    claim = Reminders::MaterializeEnrollmentStepService.new(enrollment: enrollment, now: enrollment.next_due_at + 1.minute).perform
    claim.reminder.update_columns(status: Reminder.statuses[:completed], completed_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
    enrollment.reload
  end

  def move_to_another_day(days: 3)
    appointment.update!(starts_at: starts_at + days.days, ends_at: starts_at + days.days + 30.minutes)
    appointment.reload
  end

  def perform(rules: [rule])
    described_class.new(account: account, appointment: appointment.reload, rules: rules).perform
  end

  before do
    allow(Outbound::DeliveryPolicy).to receive(:ensure!).and_return(nil)
    channel.update!(
      message_templates: [{
        'name' => 'appointment_confirmation', 'language' => 'ru', 'status' => 'APPROVED',
        'components' => [
          { 'type' => 'BODY', 'text' => 'Подтвердите запись' },
          { 'type' => 'BUTTONS', 'buttons' => [{ 'type' => 'QUICK_REPLY', 'text' => 'Подтвердить' }] }
        ]
      }]
    )
    travel_to Time.utc(2026, 11, 10, 8, 0)
    plan_the_booking
    deliver_for_the_old_date
    clear_enqueued_jobs
  end

  it 'plans the confirmation again for the new date, as for a new booking' do
    expect(two_hour_enrollments.first).to be_completed
    expect(account.reminders.where(remindable: appointment, response_action: 'confirm_appointment').pluck(:status)).to eq(['completed'])

    move_to_another_day(days: 3)
    expect { perform }.to change { account.reminders.where(remindable: appointment, response_action: 'confirm_appointment').count }.by(1)

    confirmation = automation_touches(confirmation_action_id).last
    expect(confirmation).to be_pending
    expect(confirmation).to have_attributes(response_action: 'confirm_appointment', remindable: appointment)
    expect(confirmation.metadata).to include('automation_event_name' => 'appointment_created')
    # the day before the new date (22.11 -> 23.11 15:00 in Almaty is 10:00 UTC)
    expect(confirmation.scheduled_at).to eq(Time.utc(2026, 11, 22, 10, 0))
  end

  it 'runs by itself when the appointment is moved: the confirmation is reset and asked again for the new date', :aggregate_failures do
    perform_enqueued_jobs { move_to_another_day(days: 3) }

    expect(appointment.status).to eq('scheduled')
    confirmations = account.reminders.where(remindable: appointment, response_action: 'confirm_appointment').order(:id)
    expect(confirmations.map(&:status)).to eq(%w[completed pending])
    expect(confirmations.last.scheduled_at).to eq(Time.utc(2026, 11, 22, 10, 0))
    expect(two_hour_enrollments.map(&:status)).to eq(%w[cancelled active])
  end

  it 'does not plan anything again when the time changes within the same day', :aggregate_failures do
    expect do
      perform_enqueued_jobs { appointment.update!(starts_at: starts_at + 2.hours, ends_at: starts_at + 150.minutes) }
    end.not_to change(Reminder, :count)

    expect(appointment.reload.status).to eq('confirmed')
    expect(two_hour_enrollments.map(&:status)).to eq(['completed'])
  end

  it 'plans the touch as for a new booking when the time before the visit has already passed: it is skipped, not sent late', :aggregate_failures do
    travel_to Time.utc(2026, 11, 20, 12, 0) # the day before the new date is 20.11 15:00 in Almaty (10:00 UTC), two hours ago
    move_to_another_day(days: 1)

    perform

    confirmation = automation_touches(confirmation_action_id).last
    expect(confirmation.scheduled_at).to eq(Time.utc(2026, 11, 20, 10, 0))
    expect(Reminders::ExecutionScheduleGuard.new(reminder: confirmation).perform).to eq(Reminders::ExecutionScheduleGuard::STOP)
    expect(confirmation.reload).to be_cancelled
  end

  it 'plans a deferred reminder again for the new date and retires the finished enrollment' do
    old_enrollment = two_hour_enrollments.first
    move_to_another_day(days: 3)

    perform

    expect(old_enrollment.reload).to be_cancelled
    expect(old_enrollment.metadata).to include('cancelled_reason' => 'appointment_moved_to_another_day')
    new_enrollment = two_hour_enrollments.last
    expect(new_enrollment).not_to eq(old_enrollment)
    expect(new_enrollment).to be_active
    expect(new_enrollment.next_due_at).to eq(Time.utc(2026, 11, 23, 8, 30)) # two hours before the new 10:30 UTC start
  end

  it 'does not repeat the notice, the webhook or any other action that is not timed from the visit' do
    move_to_another_day(days: 3)

    expect { perform }.not_to have_enqueued_job(WebhookJob)

    notice = account.touch_plan_enrollments.where(remindable: appointment, source_action_id: notice_action_id)
    expect(notice.pluck(:status)).to eq(['active'])
  end

  it 'does nothing a second time while the touches planned for the new date are still to go out' do
    move_to_another_day(days: 3)
    perform

    expect { perform }.to not_change(Reminder, :count).and not_change(TouchPlanEnrollment, :count)
  end

  it 'leaves an action alone while its own touch has not gone out yet (it follows the visit by itself)' do
    pending_touch = automation_touches(confirmation_action_id).first
    pending_touch.update_columns(status: Reminder.statuses[:pending], completed_at: nil) # rubocop:disable Rails/SkipsModelValidations
    move_to_another_day(days: 3)

    expect { perform }.not_to(change { account.reminders.where(response_action: 'confirm_appointment').count })
  end

  it 'plans nothing for an appointment that is no longer active' do
    move_to_another_day(days: 3)
    appointment.update_columns(status: 'cancelled') # rubocop:disable Rails/SkipsModelValidations

    expect { perform }.not_to change(Reminder, :count)
  end

  it 'plans nothing for a rule that does not match the appointment' do
    move_to_another_day(days: 3)

    expect { perform(rules: []) }.not_to change(Reminder, :count)
  end

  describe 'confirmation questions that are still open' do
    let(:confirmation_touch) { automation_touches(confirmation_action_id).first }
    let(:message) { create(:message, account: account, conversation: conversation, inbox: channel.inbox) }
    let!(:request) do
      create(:confirmation_request, account: account, conversation: conversation, reminder: confirmation_touch, subject: appointment,
                                    delivery_message: message, expires_at: starts_at + 30.minutes)
    end

    it 'expires the question the patient has not answered, so that the old message cannot confirm the new date', :aggregate_failures do
      move_to_another_day(days: 3)
      perform

      expect(request.reload).to have_attributes(status: 'expired', resolution_source: 'system')
      expect(request.resolution_metadata).to include('reason' => 'appointment_moved_to_another_day')
      expect do
        Confirmations::ResolveService.new(account: account, confirmation_request: request, decision: 'confirmed', source: 'button').perform
      end.to raise_error(ArgumentError, /already expired/)
      expect(appointment.reload.status).to eq('scheduled')
    end

    it 'keeps a question that is already answered' do
      request.update!(status: 'confirmed', resolved_at: Time.current, resolution_source: 'button')
      move_to_another_day(days: 3)
      perform

      expect(request.reload.status).to eq('confirmed')
    end

    it 'keeps a question that was not delivered yet, which is refreshed with the new date when it is sent' do
      request.update!(delivery_message: nil)
      move_to_another_day(days: 3)
      perform

      expect(request.reload.status).to eq('pending')
    end
  end
end
