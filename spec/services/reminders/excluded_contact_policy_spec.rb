require 'rails_helper'

RSpec.describe Reminders::ExcludedContactPolicy do
  include ActiveJob::TestHelper

  let(:account) { create(:account).tap { |record| record.enable_features!('scheduling') } }
  let(:resource) { create(:scheduling_resource, account: account) }
  let(:contact) { create(:contact, account: account, name: 'Excluded Person') }
  let(:other_contact) { create(:contact, account: account, name: 'Other Person') }
  let(:status_condition) do
    { 'attribute_key' => 'status', 'filter_operator' => 'equal_to', 'values' => ['scheduled'], 'query_operator' => nil }
  end
  let(:touch_action) do
    {
      action_name: 'create_touch',
      action_params: {
        body: 'Appointment reminder',
        timing_mode: 'relative',
        relative_anchor: 'appointment.starts_at',
        relative_offset_seconds: -1.hour.to_i,
        timezone: 'UTC'
      }
    }
  end
  let(:rule) do
    create(:automation_rule, account: account, event_name: 'appointment_created', conditions: [status_condition], actions: [touch_action])
  end
  let(:inbox) { create(:inbox, account: account) }
  let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: inbox) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox) }
  let(:appointment) do
    create(:scheduling_appointment, account: account, resource: resource, contact: contact, conversation: conversation,
                                    status: 'scheduled', starts_at: 2.days.from_now, ends_at: 2.days.from_now + 30.minutes)
  end

  def contact_condition(operator, ids, query_operator = nil)
    { 'attribute_key' => 'contact_id', 'filter_operator' => operator, 'values' => ids, 'query_operator' => query_operator }
  end

  def exclusion_conditions(ids = [contact.id])
    [status_condition.merge('query_operator' => 'AND'), contact_condition('not_equal_to', ids)]
  end

  def schedule_touch
    AutomationRules::AppointmentActionService.new(rule, account, appointment).perform
    account.reminders.where(remindable: appointment).sole
  end

  it 'cancels a pending touch once its contact is excluded in the rule', :aggregate_failures do
    touch = schedule_touch
    expect(touch).to be_pending

    rule.update!(conditions: exclusion_conditions)
    perform_enqueued_jobs

    expect(AutomationRules::AppointmentConditionService.new(rule.reload, appointment).perform).to be(false)
    expect(touch.reload).to have_attributes(status: 'cancelled', last_error: described_class::CANCEL_REASON)
    expect(touch.metadata).to include('cancelled_via' => described_class::CANCELLED_VIA, 'excluded_by_automation_rule_id' => rule.id)
  end

  it 'cancels a touch at send time when the list was changed without the reconcile job' do
    touch = schedule_touch
    rule.update_columns(conditions: exclusion_conditions) # rubocop:disable Rails/SkipsModelValidations

    expect(described_class.new(reminder: touch).cancel_if_excluded!).to be(true)
    expect(touch.reload).to be_cancelled
  end

  it 'keeps the touch while the list names other contacts' do
    touch = schedule_touch

    rule.update!(conditions: exclusion_conditions([other_contact.id]))
    perform_enqueued_jobs

    expect(touch.reload).to be_pending
    expect(described_class.new(reminder: touch).cancel_if_excluded!).to be(false)
  end

  it 'keeps the touch when an OR group of the rule has no exclusion of the contact' do
    touch = schedule_touch

    rule.update!(conditions: [contact_condition('not_equal_to', [contact.id], 'OR'), status_condition])
    perform_enqueued_jobs

    expect(touch.reload).to be_pending
  end

  it 'cancels the touch when every OR group lists the contact' do
    touch = schedule_touch

    rule.update!(conditions: [contact_condition('not_equal_to', [contact.id], 'OR'),
                              status_condition.merge('query_operator' => 'AND'), contact_condition('not_equal_to', [contact.id])])
    perform_enqueued_jobs

    expect(touch.reload).to be_cancelled
  end

  it 'does not read an "is" list as an exclusion' do
    touch = schedule_touch

    rule.update!(conditions: [status_condition.merge('query_operator' => 'AND'), contact_condition('equal_to', [other_contact.id])])
    perform_enqueued_jobs

    expect(touch.reload).to be_pending
  end

  it 'cancels when the patient card of the appointment is the excluded contact' do
    patient = create(:contact, account: account, name: 'Patient Card')
    appointment.update!(patient_contact: patient)
    touch = schedule_touch

    rule.update!(conditions: exclusion_conditions([patient.id]))
    perform_enqueued_jobs

    expect(touch.reload).to be_cancelled
  end

  it 'cancels when a third contact reached through the holder route is excluded' do
    touch = schedule_touch
    holder = create(:contact, account: account, name: 'Holder')
    touch.update_columns(target_contact_id: holder.id) # rubocop:disable Rails/SkipsModelValidations

    rule.update!(conditions: exclusion_conditions([holder.id]))
    perform_enqueued_jobs

    expect(touch.reload).to be_cancelled
  end

  it 'leaves touches that are not from an automation alone' do
    touch = schedule_touch
    touch.update_columns(metadata: touch.metadata.except('touch_source', Reminder::POST_DELIVERY_AUDIT_SOURCE_KEY)) # rubocop:disable Rails/SkipsModelValidations
    rule.update_columns(conditions: exclusion_conditions) # rubocop:disable Rails/SkipsModelValidations

    expect(described_class.new(reminder: touch.reload).cancel_if_excluded!).to be(false)
    expect(touch.reload).to be_pending
  end

  it 'leaves the touches of another rule alone' do
    touch = schedule_touch
    other_rule = create(:automation_rule, account: account, event_name: 'appointment_created', conditions: [status_condition],
                                          actions: [touch_action])

    other_rule.update!(conditions: exclusion_conditions)
    perform_enqueued_jobs

    expect(touch.reload).to be_pending
  end

  it 'never cancels a touch whose message already exists' do
    touch = schedule_touch
    touch.mark_processing!
    touch.mark_delivery_materialized!(123)
    rule.update_columns(conditions: exclusion_conditions) # rubocop:disable Rails/SkipsModelValidations

    expect(described_class.new(reminder: touch.reload, processing_claim: touch.processing_claim_token).cancel_if_excluded!).to be(false)
    expect(touch.reload).to be_processing
  end

  it 'cancels a processing touch only under the claim of the execution that holds it' do
    touch = schedule_touch
    claim = touch.mark_processing!
    rule.update_columns(conditions: exclusion_conditions) # rubocop:disable Rails/SkipsModelValidations

    expect(described_class.new(reminder: touch.reload, processing_claim: 'another-claim').cancel_if_excluded!).to be(false)
    expect(touch.reload).to be_processing
    expect(described_class.new(reminder: touch.reload, processing_claim: claim).cancel_if_excluded!).to be(true)
    expect(touch.reload).to be_cancelled
  end

  it 'does nothing for a touch whose rule is gone' do
    touch = schedule_touch
    touch.update_columns(metadata: touch.metadata.merge('automation_rule_id' => 0, Reminder::POST_DELIVERY_AUTOMATION_RULE_ID_KEY => 0)) # rubocop:disable Rails/SkipsModelValidations

    expect(described_class.new(reminder: touch.reload).cancel_if_excluded!).to be(false)
  end

  it 'does nothing for a touch that is not saved' do
    expect(described_class.new(reminder: Reminder.new(metadata: { 'touch_source' => 'automation' })).cancel_if_excluded!).to be(false)
  end

  context 'with a delayed follow-up of a conversation rule' do
    let(:rule) do
      create(:automation_rule, account: account, event_name: 'conversation_updated', conditions: [contact_condition('equal_to', [contact.id])],
                               actions: [{ action_name: 'create_touch', action_params: { body: 'Follow-up', delay_minutes: 30 } }])
    end

    it 'cancels the pending follow-up when the contact is excluded afterwards', :aggregate_failures do
      follow_up = AutomationRules::TouchActionService.new(rule: rule, account: account, record: conversation, entity_kind: 'conversation')
                                                     .create_touch(body: 'Follow-up', delay_minutes: 30)
      expect(follow_up).to be_pending

      rule.update!(conditions: [contact_condition('not_equal_to', [contact.id])])
      perform_enqueued_jobs

      expect(follow_up.reload).to have_attributes(status: 'cancelled', last_error: described_class::CANCEL_REASON)
    end

    it 'keeps the follow-up of another contact' do
      other_conversation = create(:conversation, account: account, inbox: inbox, contact: other_contact,
                                                 contact_inbox: create(:contact_inbox, contact: other_contact, inbox: inbox))
      follow_up = AutomationRules::TouchActionService.new(rule: rule, account: account, record: other_conversation, entity_kind: 'conversation')
                                                     .create_touch(body: 'Follow-up', delay_minutes: 30)

      rule.update!(conditions: [contact_condition('not_equal_to', [contact.id])])
      perform_enqueued_jobs

      expect(follow_up.reload).to be_pending
    end
  end
end
