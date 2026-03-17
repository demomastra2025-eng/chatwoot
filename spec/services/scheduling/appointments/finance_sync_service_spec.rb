require 'rails_helper'

RSpec.describe Scheduling::Appointments::FinanceSyncService do
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

  subject(:service_object) { described_class.new(appointment: appointment) }

  it 'creates an expense using fixed and percent compensation' do
    service_object.sync!

    expect(appointment.reload.expense.amount).to eq(7_000)
  end
end
