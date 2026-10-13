require 'rails_helper'

# Deferred (live) touches of an automation rule: the rule's "Contact is not" list is read again when the enrollment is
# reconciled and when its next step is about to be materialized.
RSpec.describe 'Excluded contact and live automation enrollments' do # rubocop:disable RSpec/DescribeClass
  include ActiveJob::TestHelper

  let(:account) { create(:account).tap { |record| record.enable_features!('scheduling', 'deferred_touch_materialization') } }
  let(:contact) { create(:contact, account: account, name: 'Excluded Person') }
  let(:other_contact) { create(:contact, account: account, name: 'Other Person') }
  let(:status_condition) do
    { 'attribute_key' => 'status', 'filter_operator' => 'equal_to', 'values' => ['scheduled'], 'query_operator' => nil }
  end
  let(:inbox) { create(:inbox, account: account) }
  let(:rule) do
    create(
      :automation_rule,
      account: account,
      event_name: 'appointment_created',
      conditions: [status_condition],
      actions: [{
        action_name: 'create_touch',
        action_params: {
          body: 'Visit reminder',
          timing_mode: 'relative',
          relative_anchor: 'appointment.starts_at',
          relative_offset_seconds: -1.day.to_i,
          target_inbox_id: inbox.id,
          timezone: 'UTC'
        }
      }]
    )
  end
  let(:appointment) do
    create(:scheduling_appointment, account: account, contact: contact, status: 'scheduled',
                                    starts_at: 3.days.from_now, ends_at: 3.days.from_now + 30.minutes)
  end
  let(:enrollment) do
    create(:contact_inbox, contact: contact, inbox: inbox)
    AutomationRules::AppointmentActionService.new(rule, account, appointment).perform
    account.touch_plan_enrollments.find_by!(automation_rule: rule, remindable: appointment)
  end

  def exclusion_conditions(ids)
    [
      status_condition.merge('query_operator' => 'AND'),
      { 'attribute_key' => 'contact_id', 'filter_operator' => 'not_equal_to', 'values' => ids, 'query_operator' => nil }
    ]
  end

  def materialize_step(target = enrollment)
    Reminders::MaterializeEnrollmentStepService.new(enrollment: target, now: target.next_due_at + 1.minute).perform
  end

  it 'materializes the next step while the contact is not excluded' do
    expect(materialize_step).to be_materialized
    expect(enrollment.reload).to be_completed
  end

  it 'materializes nothing and cancels the enrollment once the contact is excluded', :aggregate_failures do
    enrollment
    rule.update_columns(conditions: exclusion_conditions([contact.id])) # rubocop:disable Rails/SkipsModelValidations

    materialize_step(enrollment.reload)

    expect(account.reminders.where(remindable: appointment)).to be_empty
    expect(enrollment.touch_occurrence_claims).to be_empty
    expect(enrollment.reload).to be_cancelled
    expect(enrollment.metadata).to include('cancelled_reason' => Reminders::ExcludedContactPolicy::CANCEL_REASON,
                                           'cancelled_via' => Reminders::ExcludedContactPolicy::CANCELLED_VIA)
  end

  it 'still materializes for a contact that is not on the list' do
    enrollment
    rule.update_columns(conditions: exclusion_conditions([other_contact.id])) # rubocop:disable Rails/SkipsModelValidations

    expect(materialize_step(enrollment.reload)).to be_materialized
  end

  it 'cancels an already materialized, undelivered step when the rule is edited', :aggregate_failures do
    claim = materialize_step
    touch = claim.reminder
    expect(touch).to be_pending

    rule.update!(conditions: exclusion_conditions([contact.id]))
    perform_enqueued_jobs

    expect(touch.reload).to have_attributes(status: 'cancelled', last_error: Reminders::ExcludedContactPolicy::CANCEL_REASON)
    expect(enrollment.reload).to be_cancelled
  end

  it 'keeps the materialized step when the edited list names someone else' do
    touch = materialize_step.reminder

    rule.update!(conditions: exclusion_conditions([other_contact.id]))
    perform_enqueued_jobs

    expect(touch.reload).to be_pending
    expect(enrollment.reload).to be_completed
  end

  it 'preserves a step whose message already exists' do
    touch = materialize_step.reminder
    touch.mark_processing!
    touch.mark_delivery_materialized!(321)

    rule.update!(conditions: exclusion_conditions([contact.id]))
    perform_enqueued_jobs

    expect(touch.reload).to be_processing
    expect(enrollment.reload).to be_completed
  end

  it 'reconciles an enrollment of a rule without contact conditions as before' do
    touch = materialize_step.reminder

    rule.update!(name: 'Renamed', conditions: [status_condition.merge('values' => %w[scheduled confirmed])])
    perform_enqueued_jobs

    expect(touch.reload).to be_pending
    expect(enrollment.reload).to be_completed
  end
end
