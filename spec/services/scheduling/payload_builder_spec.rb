require 'rails_helper'

RSpec.describe Scheduling::PayloadBuilder do
  around do |example|
    with_modified_env(Scheduling::FinanceApiCompatibility::ENV_KEY.to_sym => nil) { example.run }
  end

  it 'includes the operation receipt attached to a provider-backed mutation' do
    appointment = build_stubbed(:scheduling_appointment)
    command = instance_double(Integrations::Medelement::ProviderCommand)
    receipt = { appointment_id: appointment.id, expected_operation: 'move_reception' }
    appointment.medelement_provider_command_receipt = command
    allow(Integrations::Medelement::ProviderCommandReceiptBuilder).to receive(:build)
      .with(command: command)
      .and_return(receipt)

    payload = described_class.appointment(appointment)

    expect(payload[:provider_command_receipt]).to eq(receipt)
  end

  it 'omits all neutral finance compatibility fields after the configured seven-day window' do
    anchor = Time.current.utc.change(usec: 0) + 10.days
    appointment = build_stubbed(:scheduling_appointment, contact: nil, conversation: nil)
    resource = build_stubbed(:scheduling_resource)
    price = build_stubbed(:scheduling_service_price)

    with_modified_env(Scheduling::FinanceApiCompatibility::ENV_KEY.to_sym => anchor.iso8601) do
      travel_to(anchor + Scheduling::FinanceApiCompatibility::WINDOW_SECONDS - 1) do
        appointment_payload = described_class.appointment(appointment)
        resource_payload = described_class.resource(resource)
        price_payload = described_class.service_price(price)
        calendar_payload = described_class.calendar(empty_calendar_payload(resources: [resource]))

        expect(appointment_payload).to include(
          prepaid_amount: 0,
          settlement_amount: 0,
          prepaid_payment_method: nil,
          settlement_payment_method: nil,
          compensation_type_snapshot: nil,
          compensation_value_snapshot: 0,
          compensation_percent_snapshot: 0,
          payments: [],
          expense: nil
        )
        expect(appointment_payload).not_to have_key(:payment_status)
        expect(resource_payload).to include(compensation_type: nil, compensation_value: 0, compensation_percent: 0)
        expect(price_payload).to include(compensation_type: nil, compensation_value: 0, compensation_percent: 0)
        expect(price_payload).to include(price: price.price)
        expect(calendar_payload).to include(payments: [], expenses: [])
        expect(calendar_payload.dig(:resources, 0)).to include(compensation_type: nil, compensation_value: 0, compensation_percent: 0)
      end

      travel_to(anchor + Scheduling::FinanceApiCompatibility::WINDOW_SECONDS) do
        appointment_payload = described_class.appointment(appointment)
        resource_payload = described_class.resource(resource)
        price_payload = described_class.service_price(price)
        calendar_payload = described_class.calendar(empty_calendar_payload(resources: [resource]))

        expect(appointment_payload).not_to include(
          :prepaid_amount,
          :settlement_amount,
          :prepaid_payment_method,
          :settlement_payment_method,
          :compensation_type_snapshot,
          :compensation_value_snapshot,
          :compensation_percent_snapshot,
          :payments,
          :expense
        )
        expect(appointment_payload).to include(service_amount: appointment.service_amount)
        expect(appointment_payload).not_to have_key(:payment_status)
        expect(resource_payload).not_to have_key(:compensation_type)
        expect(price_payload).not_to have_key(:compensation_type)
        expect(price_payload).to include(price: price.price)
        expect(calendar_payload).not_to have_key(:payments)
        expect(calendar_payload).not_to have_key(:expenses)
        expect(calendar_payload.dig(:resources, 0)).not_to have_key(:compensation_type)
      end
    end
  end

  def empty_calendar_payload(resources: [])
    {
      view: 'week',
      range: {},
      resources: resources,
      work_rules: [],
      break_rules: [],
      holidays: [],
      workday_overrides: [],
      time_offs: [],
      appointments: [],
      slots: []
    }
  end
end
