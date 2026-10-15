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

  it 'cleans up the unpaid expense after cancellation without reconciling totals above the service price' do
    actor = create(:user, account: account)
    appointment.update!(settlement_amount: 20_000, payment_status: 'paid')
    manual_payment = create(
      :scheduling_payment,
      account: account,
      appointment: appointment,
      amount: 5_000,
      payment_kind: 'payment',
      recorded_by: actor
    )
    adjustment = create(
      :scheduling_payment,
      account: account,
      appointment: appointment,
      amount: 15_000,
      payment_kind: 'adjustment',
      recorded_by: actor
    )
    expense = create(:scheduling_expense, account: account, appointment: appointment, resource: resource)
    payment_audit = appointment.payments.order(:id).pluck(:id, :amount, :payment_kind, :recorded_by_id)
    appointment.update!(service_amount: 15_000, payment_status: 'cancelled')

    expect { service_object.sync! }.not_to raise_error

    expect(appointment.reload).to have_attributes(service_amount: 15_000, payment_status: 'cancelled', expense: nil)
    expect(appointment.payments.order(:id)).to eq([manual_payment, adjustment])
    expect(appointment.payments.order(:id).pluck(:id, :amount, :payment_kind, :recorded_by_id)).to eq(payment_audit)
    expect(Scheduling::Expense.exists?(expense.id)).to be(false)
  end

  it 'cleans up the unpaid expense after cancellation without rejecting settlement below manual payments' do
    actor = create(:user, account: account)
    appointment.update!(settlement_amount: 3_000, payment_status: 'paid')
    manual_payment = create(
      :scheduling_payment,
      account: account,
      appointment: appointment,
      amount: 5_000,
      payment_kind: 'payment',
      recorded_by: actor
    )
    expense = create(:scheduling_expense, account: account, appointment: appointment, resource: resource)
    payment_audit = appointment.payments.order(:id).pluck(:id, :amount, :payment_kind, :recorded_by_id)
    appointment.update!(payment_status: 'cancelled')

    expect { service_object.sync! }.not_to raise_error

    expect(appointment.reload).to have_attributes(service_amount: 20_000, settlement_amount: 3_000, payment_status: 'cancelled', expense: nil)
    expect(appointment.payments).to eq([manual_payment])
    expect(appointment.payments.order(:id).pluck(:id, :amount, :payment_kind, :recorded_by_id)).to eq(payment_audit)
    expect(Scheduling::Expense.exists?(expense.id)).to be(false)
  end
end
