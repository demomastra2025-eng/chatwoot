require 'rails_helper'

RSpec.describe SchedulingAutomationRuleListener do
  include ActiveJob::TestHelper

  let(:listener) { described_class.instance }
  let(:account) { create(:account) }
  let(:appointment) { create(:scheduling_appointment, account: account, resource: create(:scheduling_resource, account: account)) }
  let(:condition_service) { instance_double(AutomationRules::AppointmentConditionService, perform: condition_match) }
  let(:action_service) { instance_double(AutomationRules::AppointmentActionService, perform: true) }
  let(:condition_match) { true }

  before do
    account.enable_features!('scheduling')
    allow(AutomationRules::AppointmentConditionService).to receive(:new).and_return(condition_service)
    allow(AutomationRules::AppointmentActionService).to receive(:new).and_return(action_service)
  end

  describe 'appointment_created' do
    let!(:automation_rule) do
      create(
        :automation_rule,
        account: account,
        event_name: 'appointment_created',
        conditions: [{ attribute_key: 'status', filter_operator: 'equal_to', values: ['scheduled'], query_operator: nil }],
        actions: [{ action_name: 'send_webhook_event', action_params: ['https://example.com/hooks/appointments'] }]
      )
    end
    let(:event) { Events::Base.new('appointment_created', Time.zone.now, appointment: appointment) }

    it 'invokes the appointment action service when conditions match' do
      listener.appointment_created(event)

      expect(AutomationRules::AppointmentConditionService).to have_received(:new).with(
        automation_rule,
        appointment,
        changed_attributes: nil
      )
      expect(AutomationRules::AppointmentActionService).to have_received(:new).with(
        automation_rule,
        account,
        appointment,
        changed_attributes: nil
      )
    end

    it 'does not invoke the action service when conditions do not match' do
      allow(condition_service).to receive(:perform).and_return(false)

      listener.appointment_created(event)

      expect(AutomationRules::AppointmentActionService).not_to have_received(:new)
    end
  end

  describe 'appointment_cancelled' do
    let!(:automation_rule) do
      create(
        :automation_rule,
        account: account,
        event_name: 'appointment_cancelled',
        conditions: [{ attribute_key: 'status', filter_operator: 'equal_to', values: ['cancelled'], query_operator: nil }],
        actions: [{ action_name: 'send_webhook_event', action_params: ['https://example.com/hooks/appointments'] }]
      )
    end
    let(:event) do
      Events::Base.new(
        'appointment_cancelled',
        Time.zone.now,
        appointment: appointment,
        changed_attributes: { 'status' => %w[scheduled cancelled] }
      )
    end

    it 'passes changed attributes through to the services' do
      listener.appointment_cancelled(event)

      expect(AutomationRules::AppointmentConditionService).to have_received(:new).with(
        automation_rule,
        appointment,
        changed_attributes: { 'status' => %w[scheduled cancelled] }
      )
      expect(AutomationRules::AppointmentActionService).to have_received(:new).with(
        automation_rule,
        account,
        appointment,
        changed_attributes: { 'status' => %w[scheduled cancelled] }
      )
    end
  end

  describe 'appointment_updated rescheduling' do
    let!(:automation_rule) do
      create(
        :automation_rule,
        account: account,
        event_name: 'appointment_rescheduled',
        conditions: [{ attribute_key: 'status', filter_operator: 'equal_to', values: ['scheduled'], query_operator: nil }],
        actions: [{ action_name: 'send_webhook_event', action_params: ['https://example.com/hooks/appointments'] }]
      )
    end

    it 'invokes rescheduled rules when the appointment start changes' do
      changed_attributes = { 'starts_at' => [appointment.starts_at, appointment.starts_at + 1.hour] }

      listener.appointment_updated(
        Events::Base.new('appointment_updated', Time.zone.now, appointment: appointment, changed_attributes: changed_attributes)
      )

      expect(AutomationRules::AppointmentActionService).to have_received(:new).with(
        automation_rule,
        account,
        appointment,
        changed_attributes: changed_attributes
      )
    end

    it 'does not invoke rescheduled rules for unrelated appointment updates' do
      listener.appointment_updated(
        Events::Base.new(
          'appointment_updated',
          Time.zone.now,
          appointment: appointment,
          changed_attributes: { 'client_comment' => [nil, 'Updated'] }
        )
      )

      expect(AutomationRules::AppointmentActionService).not_to have_received(:new)
    end
  end

  describe 'integration flow' do
    before do
      clear_enqueued_jobs
      clear_performed_jobs
      allow(AutomationRules::AppointmentConditionService).to receive(:new).and_call_original
      allow(AutomationRules::AppointmentActionService).to receive(:new).and_call_original
    end

    it 'applies native appointment status change actions through the listener' do
      create(
        :automation_rule,
        account: account,
        event_name: 'appointment_updated',
        conditions: [{ attribute_key: 'status', filter_operator: 'equal_to', values: ['scheduled'], query_operator: nil }],
        actions: [{ action_name: 'change_appointment_status', action_params: ['confirmed'] }]
      )

      perform_enqueued_jobs do
        listener.appointment_updated(
          Events::Base.new(
            'appointment_updated',
            Time.zone.now,
            appointment: appointment,
            changed_attributes: { 'client_comment' => [nil, 'Updated from listener'] }
          )
        )
      end

      expect(appointment.reload.status).to eq('confirmed')
    end

    it 'does not recurse into follow-up appointment rules triggered by automation-written updates' do
      create(
        :automation_rule,
        account: account,
        event_name: 'appointment_updated',
        conditions: [{ attribute_key: 'status', filter_operator: 'equal_to', values: ['scheduled'], query_operator: nil }],
        actions: [{ action_name: 'change_appointment_status', action_params: ['confirmed'] }]
      )
      create(
        :automation_rule,
        account: account,
        event_name: 'appointment_updated',
        conditions: [{ attribute_key: 'status', filter_operator: 'equal_to', values: ['confirmed'], query_operator: nil }],
        actions: [{ action_name: 'change_appointment_status', action_params: ['completed'] }]
      )

      perform_enqueued_jobs do
        listener.appointment_updated(
          Events::Base.new(
            'appointment_updated',
            Time.zone.now,
            appointment: appointment,
            changed_attributes: { 'client_comment' => [nil, 'Initial update'] }
          )
        )
      end

      expect(appointment.reload.status).to eq('confirmed')
    end

    it 'applies native appointment payment cancellation actions without looping' do
      account.enable_features!('scheduling_finance')
      appointment.update!(
        prepaid_amount: 3_000,
        prepaid_payment_method: 'cash',
        payment_status: 'prepaid'
      )

      create(
        :automation_rule,
        account: account,
        event_name: 'appointment_updated',
        conditions: [{ attribute_key: 'status', filter_operator: 'equal_to', values: ['scheduled'], query_operator: nil }],
        actions: [{ action_name: 'cancel_appointment_payment', action_params: [] }]
      )
      create(
        :automation_rule,
        account: account,
        event_name: 'appointment_updated',
        conditions: [{ attribute_key: 'payment_status', filter_operator: 'equal_to', values: ['cancelled'], query_operator: nil }],
        actions: [{ action_name: 'change_appointment_status', action_params: ['cancelled'] }]
      )

      perform_enqueued_jobs do
        listener.appointment_updated(
          Events::Base.new(
            'appointment_updated',
            Time.zone.now,
            appointment: appointment,
            changed_attributes: { 'client_comment' => [nil, 'Trigger finance automation'] }
          )
        )
      end

      appointment.reload
      expect(appointment.prepaid_amount).to eq(0)
      expect(appointment.prepaid_payment_method).to be_nil
      expect(appointment.payment_status).to eq('cancelled')
      expect(appointment.status).to eq('scheduled')
    end
  end
end
