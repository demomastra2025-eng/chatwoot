require 'rails_helper'

# A contact merged into another one must not end the exclusion (or the targeting) a rule's "Contact" condition made.
RSpec.describe Contacts::ReferenceMergeService do
  include ActiveJob::TestHelper

  let(:account) { create(:account).tap { |record| record.enable_features!('scheduling', 'crm_deals') } }
  let(:base) { create(:contact, account: account, name: 'Base') }
  let(:mergee) { create(:contact, account: account, name: 'Mergee') }
  let(:inbox) { create(:inbox, account: account) }
  let(:conversation) do
    create(:conversation, account: account, inbox: inbox, contact: mergee, contact_inbox: create(:contact_inbox, contact: mergee, inbox: inbox))
  end
  let(:appointment) do
    create(:scheduling_appointment, account: account, contact: mergee, conversation: conversation, status: 'scheduled',
                                    starts_at: 2.days.from_now, ends_at: 2.days.from_now + 30.minutes)
  end

  def contact_condition(operator, values, query_operator = nil)
    { 'attribute_key' => 'contact_id', 'filter_operator' => operator, 'values' => values, 'query_operator' => query_operator }
  end

  def rule_for(event_name, conditions, actions: [{ action_name: 'send_webhook_event', action_params: ['https://example.com/hooks/automation'] }])
    create(:automation_rule, account: account, event_name: event_name, conditions: conditions, actions: actions)
  end

  def merge!
    ContactMergeAction.new(account: account, base_contact: base, mergee_contact: mergee).perform
  end

  def conversation_matches?(rule)
    AutomationRules::ConditionsFilterService.new(rule.reload, conversation.reload, { changed_attributes: {} }).perform
  end

  it 'keeps a conversation rule skipping the person after the contact is merged', :aggregate_failures do
    rule = rule_for('conversation_created', [contact_condition('not_equal_to', [mergee.id])],
                    actions: [{ action_name: 'send_message', action_params: ['Hello'] }])
    expect(conversation_matches?(rule)).to be(false)

    merge!

    expect(rule.reload.conditions).to eq([contact_condition('not_equal_to', [base.id])])
    expect(conversation.reload.contact_id).to eq(base.id)
    expect(conversation_matches?(rule)).to be(false)
  end

  it 'keeps an appointment rule skipping the booking contact after the contact is merged', :aggregate_failures do
    rule = rule_for('appointment_created', [{ 'attribute_key' => 'status', 'filter_operator' => 'equal_to', 'values' => ['scheduled'],
                                              'query_operator' => 'AND' }, contact_condition('not_equal_to', [mergee.id])])
    expect(AutomationRules::AppointmentConditionService.new(rule, appointment).perform).to be(false)

    merge!

    expect(appointment.reload.contact_id).to eq(base.id)
    expect(rule.reload.conditions.last['values']).to eq([base.id])
    expect(AutomationRules::AppointmentConditionService.new(rule, appointment).perform).to be(false)
  end

  it 'keeps an appointment rule skipping the patient card after the card is merged' do
    patient = create(:contact, account: account, name: 'Patient card')
    appointment.update!(patient_contact: patient)
    rule = rule_for('appointment_created', [contact_condition('not_equal_to', [patient.id])])

    described_class.new(account: account, base_contact: base, mergee_contact: patient).perform

    expect(appointment.reload.patient_contact_id).to eq(base.id)
    expect(AutomationRules::AppointmentConditionService.new(rule.reload, appointment).perform).to be(false)
  end

  it 'keeps a deal rule skipping the person after the contact is merged', :aggregate_failures do
    deal = create(:crm_deal, account: account)
    create(:crm_deal_contact, deal: deal, contact: mergee, primary: true)
    rule = rule_for('deal_updated', [contact_condition('not_equal_to', [mergee.id])])
    expect(AutomationRules::CrmConditionService.new(rule, deal, entity_kind: 'deal').perform).to be(false)

    merge!

    expect(rule.reload.conditions.first['values']).to eq([base.id])
    expect(AutomationRules::CrmConditionService.new(rule, deal.reload, entity_kind: 'deal').perform).to be(false)
  end

  it 'keeps an "is" list pointing at the person after the contact is merged' do
    rule = rule_for('conversation_created', [contact_condition('equal_to', [mergee.id.to_s, base.id])],
                    actions: [{ action_name: 'send_message', action_params: ['Hello'] }])
    expect(conversation_matches?(rule)).to be(true)

    merge!

    expect(rule.reload.conditions.first['values']).to eq([base.id])
    expect(conversation_matches?(rule)).to be(true)
  end

  it 'keeps the other values of the list and their order' do
    third = create(:contact, account: account)
    rule = rule_for('appointment_created', [contact_condition('not_equal_to', [third.id, mergee.id.to_s])])

    merge!

    expect(rule.reload.conditions.first['values']).to eq([third.id, base.id])
  end

  it 'swaps the contact in every contact condition of the rule and leaves the other conditions alone' do
    status = { 'attribute_key' => 'status', 'filter_operator' => 'equal_to', 'values' => ['scheduled'], 'query_operator' => 'OR' }
    rule = rule_for('appointment_created', [contact_condition('not_equal_to', [mergee.id], 'OR'), status,
                                            contact_condition('equal_to', [mergee.id])])

    merge!

    conditions = rule.reload.conditions
    expect(conditions.map { |condition| condition['values'] }).to eq([[base.id], ['scheduled'], [base.id]])
  end

  it 'does not touch the rules of other accounts, other contacts or a custom attribute called contact_id' do
    other_account = create(:account)
    foreign_rule = create(:automation_rule, account: other_account, event_name: 'conversation_created', conditions: [],
                                            actions: [{ action_name: 'send_message', action_params: ['Hello'] }])
    foreign_rule.update_columns(conditions: [contact_condition('not_equal_to', [mergee.id])]) # rubocop:disable Rails/SkipsModelValidations
    unrelated = rule_for('appointment_created', [contact_condition('not_equal_to', [create(:contact, account: account).id])])
    custom_attribute = contact_condition('equal_to', [mergee.id.to_s]).merge('custom_attribute_type' => 'contact_attribute')
    custom_rule = rule_for('conversation_created', [custom_attribute], actions: [{ action_name: 'send_message', action_params: ['Hello'] }])
    custom_rule.update_columns(conditions: [custom_attribute]) # rubocop:disable Rails/SkipsModelValidations
    updated_at = [unrelated.reload.updated_at, custom_rule.reload.updated_at]

    merge!

    expect(foreign_rule.reload.conditions).to eq([contact_condition('not_equal_to', [mergee.id])])
    expect([unrelated.reload.updated_at, custom_rule.reload.updated_at]).to eq(updated_at)
    expect(custom_rule.conditions).to eq([custom_attribute])
  end

  it 'swaps the contact even for a rule that no longer passes validation' do
    rule = rule_for('appointment_created', [contact_condition('not_equal_to', [mergee.id])])
    rule.update_columns(actions: [{ 'action_name' => 'removed_action', 'action_params' => [] }]) # rubocop:disable Rails/SkipsModelValidations

    expect { merge! }.not_to raise_error

    expect(rule.reload.conditions.first['values']).to eq([base.id])
  end

  it 'cancels the touch that moved to the base contact because of the exclusion' do
    touch_action = {
      action_name: 'create_touch',
      action_params: {
        body: 'Reminder',
        timing_mode: 'relative',
        relative_anchor: 'appointment.starts_at',
        relative_offset_seconds: -1.hour.to_i,
        timezone: 'UTC'
      }
    }
    rule = rule_for('appointment_created', [contact_condition('not_equal_to', [create(:contact, account: account).id])],
                    actions: [touch_action])
    AutomationRules::AppointmentActionService.new(rule, account, appointment).perform
    touch = account.reminders.where(remindable: appointment).sole
    rule.update_columns(conditions: [contact_condition('not_equal_to', [mergee.id])]) # rubocop:disable Rails/SkipsModelValidations

    merge!

    expect(touch.reload.target_contact_id).to eq(base.id)
    expect(Reminders::ExcludedContactPolicy.new(reminder: touch).cancel_if_excluded!).to be(true)
    expect(touch.reload).to be_cancelled
  end
end
