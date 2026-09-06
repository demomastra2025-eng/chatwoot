require 'rails_helper'

RSpec.describe Integrations::Medelement::AppointmentProviderCommandReceiptLookupService do
  let(:account) { build_stubbed(:account) }
  let(:appointment) { build_stubbed(:scheduling_appointment, account: account) }
  let(:scope) { instance_double(ActiveRecord::Relation) }

  it 'attaches the durable operation command to an idempotent replay' do
    command = instance_double(Integrations::Medelement::ProviderCommand)
    ordered_scope = instance_double(ActiveRecord::Relation, first: command)
    allow(Integrations::Medelement::ProviderCommand).to receive(:where)
      .with(account_id: account.id, appointment_id: appointment.id, operation: 'create_reception')
      .and_return(scope)
    allow(scope).to receive(:order).with(created_at: :desc, id: :desc).and_return(ordered_scope)

    result = described_class.new(account: account, appointment: appointment, operation: 'create_reception').perform

    expect(result).to eq(command)
    expect(appointment.medelement_provider_command_receipt).to eq(command)
  end

  it 'fails closed while a pending provider mutation has no durable command' do
    pending_attributes = {
      Integrations::Medelement::AppointmentProviderStatus::ATTRIBUTE_KEY =>
        Integrations::Medelement::AppointmentProviderStatus::PENDING
    }
    appointment.custom_attributes = pending_attributes
    ordered_scope = instance_double(ActiveRecord::Relation, first: nil)
    allow(Integrations::Medelement::ProviderCommand).to receive(:where).and_return(scope)
    allow(scope).to receive(:order).and_return(ordered_scope)

    expect do
      described_class.new(account: account, appointment: appointment, operation: 'create_reception').perform
    end.to raise_error(Scheduling::Error) { |error| expect(error.code).to eq('MEDELEMENT_COMMAND_RECEIPT_UNAVAILABLE') }
  end
end
