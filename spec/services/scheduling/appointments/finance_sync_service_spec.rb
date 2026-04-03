require 'rails_helper'

RSpec.describe Scheduling::Appointments::FinanceSyncService do
  subject(:service_object) { described_class.new(appointment: appointment) }

  let(:account) { create(:account) }
  let(:resource) do
    create(
      :scheduling_resource,
      account: account,
      compensation_type: 'fixed_plus_percent',
      compensation_value: 5_000,
      compensation_percent: 10
    )
  end
  let(:service) { create(:scheduling_service, account: account, base_price: 20_000) }
  let(:appointment) do
    create(
      :scheduling_appointment,
      account: account,
      resource: resource,
      service: service,
      service_amount: 20_000,
      compensation_type_snapshot: 'fixed_plus_percent',
      compensation_value_snapshot: 5_000,
      compensation_percent_snapshot: 10,
      payment_status: 'paid',
      settlement_amount: 20_000,
      settlement_payment_method: 'cash'
    )
  end

  it 'creates an expense using fixed and percent compensation' do
    service_object.sync!

    expect(appointment.reload.expense.amount).to eq(7_000)
  end

  it 'refuses to mark an appointment as paid when required managed fields are missing' do
    create(
      :crm_field_definition,
      account: account,
      entity_kind: 'appointment',
      key: 'visit_reason',
      label: 'Visit reason',
      required: true
    )
    appointment.update!(
      payment_status: 'awaiting_payment',
      settlement_amount: 0,
      settlement_payment_method: nil,
      custom_attributes: {}
    )

    expect do
      service_object.add_payment!(amount: 20_000, payment_method: 'cash')
    end.to raise_error(
      Scheduling::Error,
      'Complete required fields before marking the appointment as paid: Visit reason'
    )

    appointment.reload
    expect(appointment.payment_status).to eq('awaiting_payment')
    expect(appointment.payments).to be_empty
    expect(appointment.expense).to be_nil
  end

  it 'does not require booking intake-only fields when marking an appointment as paid' do
    create(
      :crm_field_definition,
      account: account,
      entity_kind: 'appointment',
      key: 'triage_note',
      label: 'Triage note',
      required: true,
      rules: { contexts: ['booking_intake'] }
    )
    appointment.update!(
      payment_status: 'awaiting_payment',
      settlement_amount: 0,
      settlement_payment_method: nil,
      custom_attributes: {}
    )

    expect do
      service_object.add_payment!(amount: 20_000, payment_method: 'cash')
    end.not_to raise_error

    appointment.reload
    expect(appointment.payment_status).to eq('paid')
  end
end
