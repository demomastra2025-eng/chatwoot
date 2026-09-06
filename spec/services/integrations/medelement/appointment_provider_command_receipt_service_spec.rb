require 'rails_helper'

RSpec.describe Integrations::Medelement::AppointmentProviderCommandReceiptService do
  include ActiveJob::TestHelper

  it 'preserves move changes captured before the appointment is reloaded' do
    account = create(:account)
    assistant = create(:captain_assistant, account: account)
    resource = create(
      :scheduling_resource,
      account: account,
      custom_attributes: { 'medelement_specialist_code' => 'specialist-1' }
    )
    appointment = create(:scheduling_appointment, account: account, resource: resource)
    previous_starts_at = appointment.starts_at
    appointment.update!(starts_at: previous_starts_at + 1.hour, ends_at: appointment.ends_at + 1.hour)
    service = described_class.new(appointment: appointment, actor: assistant, new_record: false)
    appointment.reload
    command = instance_double(Integrations::Medelement::ProviderCommand)
    outbound_service = instance_double(Integrations::Medelement::OutboundChangeService, perform: command)
    expect(Integrations::Medelement::OutboundChangeService).to receive(:new).with(
      hash_including(
        event_name: 'appointment_updated',
        change: hash_including(
          changed_attributes: hash_including('starts_at' => [previous_starts_at, previous_starts_at + 1.hour])
        )
      )
    ).and_return(outbound_service)

    expect(service.perform).to eq(command)
    expect(appointment.medelement_provider_command_receipt).to eq(command)
  end

  it 'fails the synchronous contract instead of returning a mutation without a receipt' do
    account = create(:account)
    actor = create(:user, account: account)
    resource = create(:scheduling_resource, account: account)
    appointment = create(
      :scheduling_appointment,
      account: account,
      resource: resource,
      custom_attributes: {
        Integrations::Medelement::AppointmentProviderStatus::ATTRIBUTE_KEY =>
          Integrations::Medelement::AppointmentProviderStatus::PENDING
      }
    )
    service = described_class.new(appointment: appointment, actor: actor, new_record: true)
    allow(Integrations::Medelement::OutboundChangeService).to receive(:new).and_raise(StandardError, 'storage unavailable')

    expect { service.perform }
      .to raise_error(Scheduling::Error) { |error| expect(error.code).to eq('MEDELEMENT_COMMAND_RECEIPT_UNAVAILABLE') }
    expect(Integrations::Medelement::OutboundChangeJob).to have_been_enqueued
  end
end
