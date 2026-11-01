require 'rails_helper'

RSpec.describe Reminders::BackfillAutomationRuleEnrollmentsService do
  include ActiveJob::TestHelper

  let(:account) { create(:account, limits: { non_web_inboxes: 10 }).tap { |a| a.enable_features!('scheduling', 'deferred_touch_materialization') } }
  let(:contact) { create(:contact, account: account) }
  let(:channel) do
    create(:channel_whatsapp, account: account, provider: 'whatsapp_cloud', sync_templates: false,
                              validate_provider_config: false)
  end
  let(:appointment) do
    contact_inbox = create(:contact_inbox, contact: contact, inbox: channel.inbox)
    conversation = create(:conversation, account: account, inbox: channel.inbox, contact: contact,
                                         contact_inbox: contact_inbox)
    start = 3.days.from_now
    create(:scheduling_appointment, account: account, contact: contact, conversation: conversation,
                                    starts_at: start, ends_at: start + 30.minutes)
  end
  let(:rule) do
    create(:automation_rule, account: account, active: false, event_name: 'appointment_created',
                             conditions: [{ attribute_key: 'source', filter_operator: 'is_present', values: [], query_operator: nil }],
                             actions: [
                               { action_name: 'create_touch', action_params: {
                                 content_kind: 'channel_template', target_inbox_id: channel.inbox.id,
                                 template_params: { name: 'appointment_confirmation', language: 'ru' },
                                 timing_mode: 'relative', relative_anchor: 'appointment.starts_at',
                                 relative_offset_seconds: -1.day.to_i,
                                 relative_time_mode: 'fixed_time_of_day', relative_time_of_day: '15:00',
                                 response_action: 'confirm_appointment', response_button_index: 0
                               } }
                             ])
  end

  before do
    channel.update!(message_templates: [
                      { 'name' => 'appointment_confirmation', 'language' => 'ru', 'status' => 'APPROVED', 'components' => [
                        { 'type' => 'BODY', 'text' => 'Подтвердите запись' },
                        { 'type' => 'BUTTONS', 'buttons' => [{ 'type' => 'QUICK_REPLY', 'text' => 'Подтвердить' }] }
                      ] }
                    ])
    appointment
    clear_enqueued_jobs
  end

  it 'plans and creates a direct confirmation reminder once for an old future visit' do
    rule.update!(active: true)
    service = described_class.new(rule: rule, activation_time: rule.updated_at)
    expect(service.plan).to contain_exactly(include(appointment_id: appointment.id, kind: 'direct'))

    service.perform
    service.perform

    touches = account.reminders.where(remindable: appointment)
    expect(touches.count).to eq(1)
    expect(touches.first.response_action).to eq('confirm_appointment')
  end

  it 'runs the same backfill when an active notification rule is created' do
    source = rule
    new_rule = source.dup
    new_rule.active = true

    perform_enqueued_jobs { new_rule.save! }

    expect(account.reminders.where(remindable: appointment).count).to eq(1)
  end

  it 'does not plan a day-before step whose time already passed' do
    appointment.update!(starts_at: 1.hour.from_now, ends_at: 90.minutes.from_now)
    rule.update!(active: true)
    expect(described_class.new(rule: rule, activation_time: rule.updated_at).plan).to be_empty
  end

  it 'recreates one future direct reminder after an off-on toggle' do
    rule.update!(active: true)
    described_class.new(rule: rule, activation_time: rule.updated_at).perform
    rule.update!(active: false)
    rule.update!(active: true)
    described_class.new(rule: rule, activation_time: rule.updated_at).perform
    rule.update!(active: false)
    rule.update!(active: true)
    described_class.new(rule: rule, activation_time: rule.updated_at).perform

    touches = account.reminders.where(remindable: appointment)
    expect(touches.count).to eq(3)
    expect(touches.open_statuses.count).to eq(1)
  end

  it 'skips backfilling visits with fewer minutes remaining than min_minutes_before_appointment' do
    rule.update!(min_minutes_before_appointment: 5_000, active: true)
    expect(described_class.new(rule: rule, activation_time: rule.updated_at).plan).to be_empty

    rule.update!(min_minutes_before_appointment: 3_000)
    expect(described_class.new(rule: rule, activation_time: rule.updated_at).plan).to contain_exactly(
      include(appointment_id: appointment.id, kind: 'direct')
    )
  end
end
