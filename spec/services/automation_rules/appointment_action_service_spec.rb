require 'rails_helper'

RSpec.describe AutomationRules::AppointmentActionService do
  include ActiveJob::TestHelper

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
end
