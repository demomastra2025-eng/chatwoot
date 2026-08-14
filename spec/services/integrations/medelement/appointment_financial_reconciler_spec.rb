require 'rails_helper'

RSpec.describe Integrations::Medelement::AppointmentFinancialReconciler do
  let(:appointment) do
    instance_double(
      Scheduling::Appointment,
      id: 42,
      persisted?: true,
      service_amount: 3000,
      prepaid_amount: 0,
      settlement_amount: 0,
      payment_status: 'awaiting_payment'
    )
  end
  let(:conflict_tracker) { instance_double(Integrations::Medelement::ConflictTracker, record!: true) }

  it 'preserves the local amount without a mismatch when provider price is absent' do
    attributes = described_class.new(
      appointment: appointment,
      reception: { 'RECEPTION_CODE' => 'reception-1', 'SERVICES' => [{ 'NOMENCLATURE_CODE' => 'service-1' }] },
      conflict_tracker: conflict_tracker
    ).attributes

    expect(attributes[:service_amount]).to eq(3000)
    expect(conflict_tracker).not_to have_received(:record!)
  end

  it 'treats an explicit zero provider price as a known free-service amount' do
    described_class.new(
      appointment: appointment,
      reception: { 'RECEPTION_CODE' => 'reception-1', 'SERVICES' => [{ 'PRICE' => 0, 'QUANTITY' => 1 }] },
      conflict_tracker: conflict_tracker
    ).attributes

    expect(conflict_tracker).to have_received(:record!).with(
      hash_including(
        conflict_type: 'appointment_amount_mismatch',
        details: hash_including(appointment_id: 42, reception_code: 'reception-1', provider_amount: 0)
      )
    )
  end

  it 'excludes soft-deleted provider service rows from the amount' do
    new_appointment = instance_double(Scheduling::Appointment, persisted?: false)

    attributes = described_class.new(
      appointment: new_appointment,
      reception: {
        'SERVICES' => [
          { 'PRICE' => 1000, 'QUANTITY' => 2, 'DELETED' => 0 },
          { 'PRICE' => 9000, 'QUANTITY' => 1, 'DELETED' => 1 }
        ]
      }
    ).attributes

    expect(attributes[:service_amount]).to eq(2000)
  end
end
