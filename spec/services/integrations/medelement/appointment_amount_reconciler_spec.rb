require 'rails_helper'

RSpec.describe Integrations::Medelement::AppointmentAmountReconciler do
  let(:resource) { instance_double(Scheduling::Resource, id: 15) }
  let(:price) { instance_double(Scheduling::ServicePrice, resource_id: 15, active?: true, price: 5000) }
  let(:service) { instance_double(Scheduling::Service, base_price: 4000, prices: instance_double(ActiveRecord::Relation, find_by: price)) }
  let(:services) { [service] }
  let(:appointment) { instance_double(Scheduling::Appointment, id: 42, persisted?: true, service_amount: 3000) }
  let(:conflict_tracker) { instance_double(Integrations::Medelement::ConflictTracker, record!: true) }

  def reconcile(reception:, current: appointment)
    described_class.new(
      appointment: current,
      reception: reception,
      resource: resource,
      services: services,
      conflict_tracker: conflict_tracker
    ).attributes
  end

  it 'preserves a recorded amount when the provider supplies no price' do
    expect(reconcile(reception: { 'SERVICES' => [{ 'NOMENCLATURE_CODE' => 'service-1' }] })).to eq(service_amount: 3000)
    expect(conflict_tracker).not_to have_received(:record!)
  end

  it 'preserves a recorded sold amount and reports a provider discrepancy, including an explicit zero' do
    attributes = reconcile(reception: { 'RECEPTION_CODE' => 'reception-1', 'SERVICES' => [{ 'PRICE' => 0 }] })

    expect(attributes).to eq(service_amount: 3000)
    expect(conflict_tracker).to have_received(:record!).with(
      hash_including(
        conflict_type: 'appointment_amount_mismatch',
        details: hash_including(appointment_id: 42, local_amount: 3000, provider_amount: 0)
      )
    ).once
  end

  it 'prices new records from active provider service rows without soft-deleted entries' do
    new_appointment = instance_double(Scheduling::Appointment, persisted?: false)
    attributes = reconcile(
      current: new_appointment,
      reception: { 'SERVICES' => [{ 'PRICE' => 1000, 'QUANTITY' => 2 }, { 'PRICE' => 9000, 'DELETED' => 1 }] }
    )

    expect(attributes).to eq(service_amount: 2000)
    expect(conflict_tracker).not_to have_received(:record!)
  end

  it 'uses the selected service price when the provider does not send a price for a new record' do
    new_appointment = instance_double(Scheduling::Appointment, persisted?: false)

    expect(reconcile(current: new_appointment, reception: { 'SERVICES' => [] })).to eq(service_amount: 5000)
  end
end
