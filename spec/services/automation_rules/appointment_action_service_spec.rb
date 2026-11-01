require 'rails_helper'

RSpec.describe AutomationRules::AppointmentActionService do
  include ActiveJob::TestHelper
  include ActiveSupport::Testing::TimeHelpers

  let(:account) { create(:account) }
  let(:appointment) { create(:scheduling_appointment, account: account, resource: create(:scheduling_resource, account: account)) }
  let(:rule) do
    create(
      :automation_rule,
      account: account,
      event_name: 'appointment_updated',
      conditions: [{ attribute_key: 'status', filter_operator: 'equal_to', values: ['scheduled'], query_operator: nil }],
      actions: [{ action_name: 'send_webhook_event', action_params: ['https://example.com/hooks/appointments'] }]
    )
  end

  before do
    account.enable_features!('scheduling')
  end

  it 'enqueues a webhook with appointment payload and changed attributes' do
    service = described_class.new(
      rule,
      account,
      appointment,
      changed_attributes: { 'status' => %w[scheduled completed] }
    )

    expect do
      service.perform
    end.to have_enqueued_job(WebhookJob).with(
      'https://example.com/hooks/appointments',
      hash_including(
        event: 'automation_event.appointment_updated',
        appointment: hash_including(id: appointment.id, status: appointment.status),
        changed_attributes: [{ 'status' => { previous_value: 'scheduled', current_value: 'completed' } }]
      )
    )
  end

  it 'suppresses a confirmation when the visit is less than one hour away' do
    rule.update!(event_name: 'appointment_created')
    appointment.update_columns(created_at: appointment.starts_at - 30.minutes) # rubocop:disable Rails/SkipsModelValidations

    expect { described_class.new(rule, account, appointment.reload).perform }.not_to have_enqueued_job(WebhookJob)
  end

  it 'allows a rule with an explicit smaller lead time' do
    rule.update!(event_name: 'appointment_created',
                 conditions: [{ attribute_key: 'lead_time_minutes', filter_operator: 'is_greater_than', values: ['10'] }])
    appointment.update_columns(created_at: appointment.starts_at - 30.minutes) # rubocop:disable Rails/SkipsModelValidations

    expect { described_class.new(rule, account, appointment.reload).perform }.to have_enqueued_job(WebhookJob)
  end

  it 'updates appointment status through the native upsert path' do
    status_rule = create(
      :automation_rule,
      account: account,
      event_name: 'appointment_updated',
      conditions: [{ attribute_key: 'status', filter_operator: 'equal_to', values: ['scheduled'], query_operator: nil }],
      actions: [{ action_name: 'change_appointment_status', action_params: ['confirmed'] }]
    )

    described_class.new(status_rule, account, appointment).perform

    expect(appointment.reload.status).to eq('confirmed')
  end

  it 'keeps legacy appointment payment cancellation actions as a no-op' do
    appointment.update!(
      prepaid_amount: 4_000,
      prepaid_payment_method: 'cash',
      settlement_amount: 1_000,
      settlement_payment_method: 'cash',
      payment_status: 'prepaid'
    )

    cancel_payment_rule = create(
      :automation_rule,
      account: account,
      event_name: 'appointment_updated',
      conditions: [{ attribute_key: 'status', filter_operator: 'equal_to', values: ['scheduled'], query_operator: nil }],
      actions: [{ action_name: 'cancel_appointment_payment', action_params: [] }]
    )

    described_class.new(cancel_payment_rule, account, appointment).perform

    appointment.reload
    expect(appointment).to have_attributes(
      prepaid_amount: 4_000,
      prepaid_payment_method: 'cash',
      settlement_amount: 1_000,
      settlement_payment_method: 'cash',
      payment_status: 'prepaid',
      status: 'scheduled'
    )
  end

  describe 'configured min_minutes_before_appointment' do
    around { |example| travel_to(Time.zone.parse('2026-11-02 10:00:00')) { example.run } }

    let(:contact) { create(:contact, account: account, phone_number: '+77000000099') }
    let(:conversation) { create(:conversation, account: account, contact: contact) }
    let(:touch_rule) do
      create(
        :automation_rule,
        account: account,
        event_name: 'appointment_created',
        min_minutes_before_appointment: 60,
        conditions: [],
        actions: [
          { action_name: 'create_touch', action_params: [{
            action_type: 'send_message', content_kind: 'free_text', body: 'Вы записаны',
            timing_mode: 'relative', relative_anchor: 'touch.created_at', relative_offset_seconds: 60
          }] },
          { action_name: 'send_webhook_event', action_params: ['https://example.com/hooks/lead'] }
        ]
      )
    end

    def appointment_at(offset)
      create(:scheduling_appointment, account: account, resource: create(:scheduling_resource, account: account),
                                      contact: contact, conversation: conversation,
                                      starts_at: Time.current + offset, ends_at: Time.current + offset + 30.minutes)
    end

    it 'skips notifications when appointment is in 59 minutes or in the past' do
      [59.minutes, 0.minutes, -10.minutes].each do |offset|
        appt = appointment_at(offset)
        clear_enqueued_jobs
        described_class.new(touch_rule, account, appt).perform

        expect(account.reminders.where(remindable: appt)).to be_empty
      end
      expect(enqueued_jobs.count { |job| job[:job] == WebhookJob }).to eq(0)
    end

    it 'sends notifications when appointment is in 60 minutes or 61 minutes' do
      appt60 = appointment_at(60.minutes)
      appt61 = appointment_at(61.minutes)
      clear_enqueued_jobs

      described_class.new(touch_rule, account, appt60).perform
      described_class.new(touch_rule, account, appt61).perform

      expect(account.reminders.where(remindable: appt60).count).to eq(1)
      expect(account.reminders.where(remindable: appt61).count).to eq(1)
      expect(enqueued_jobs.count { |job| job[:job] == WebhookJob }).to eq(2)
    end

    it 'evaluates remaining minutes from current time on reschedule and update rules' do
      reschedule_rule = create(
        :automation_rule, account: account, event_name: 'appointment_rescheduled',
                          min_minutes_before_appointment: 60, conditions: [],
                          actions: [{ action_name: 'send_webhook_event', action_params: ['https://example.com/hooks/reschedule'] }]
      )
      short_appt = appointment_at(59.minutes)
      short_appt.update_columns(created_at: 3.days.ago) # rubocop:disable Rails/SkipsModelValidations
      ok_appt = appointment_at(60.minutes)
      ok_appt.update_columns(created_at: 3.days.ago) # rubocop:disable Rails/SkipsModelValidations
      clear_enqueued_jobs

      described_class.new(reschedule_rule, account, short_appt.reload).perform
      expect(enqueued_jobs.count { |job| job[:job] == WebhookJob }).to eq(0)

      described_class.new(reschedule_rule, account, ok_appt.reload).perform
      expect(enqueued_jobs.count { |job| job[:job] == WebhookJob }).to eq(1)
    end

    it 'sends at 15 minutes when min_minutes_before_appointment is nil on non-confirmation or reschedule rules' do
      unconfigured_reschedule = create(
        :automation_rule, account: account, event_name: 'appointment_rescheduled',
                          min_minutes_before_appointment: nil, conditions: [],
                          actions: [{ action_name: 'send_webhook_event', action_params: ['https://example.com/hooks/reschedule'] }]
      )
      appt15 = appointment_at(15.minutes)
      clear_enqueued_jobs

      described_class.new(unconfigured_reschedule, account, appt15).perform
      expect(enqueued_jobs.count { |job| job[:job] == WebhookJob }).to eq(1)
    end

    it 'respects explicit smaller min_minutes_before_appointment (15 min) on appointment_created confirmations' do
      touch_rule.update!(min_minutes_before_appointment: 15)
      appt14 = appointment_at(14.minutes)
      appt15 = appointment_at(15.minutes)

      described_class.new(touch_rule, account, appt14).perform
      described_class.new(touch_rule, account, appt15).perform

      expect(account.reminders.where(remindable: appt14)).to be_empty
      expect(account.reminders.where(remindable: appt15).count).to eq(1)
    end
  end
end
