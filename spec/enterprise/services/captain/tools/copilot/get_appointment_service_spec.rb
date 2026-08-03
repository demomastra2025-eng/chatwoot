require 'rails_helper'

RSpec.describe Captain::Tools::Copilot::GetAppointmentService do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:service) { described_class.new(assistant, user: user) }

  before do
    account.enable_features!('scheduling')
  end

  it 'returns a structured failure when the appointment is missing' do
    expect(service.execute(appointment_id: 999)).to eq('ERROR: Appointment not found')
  end

  it 'rejects a non-positive appointment id before lookup' do
    expect { service.execute(appointment_id: 0) }.to raise_error(ArgumentError, 'appointment_id is required')
  end

  it 'returns a normalized appointment payload' do
    resource = create(:scheduling_resource, account: account, name: 'Dr. Aida')
    contact = create(:contact, account: account, name: 'Aruzhan')
    scheduling_service = create(:scheduling_service, account: account, name: 'Consultation', duration_min: 30)
    conversation = create(:conversation, account: account, contact: contact)
    appointment = create(
      :scheduling_appointment,
      account: account,
      resource: resource,
      contact: contact,
      conversation: conversation,
      service: scheduling_service
    )
    expect(Scheduling::PayloadBuilder).to receive(:appointment).with(
      satisfy do |record|
        record.association(:conversation).loaded? &&
          record.conversation.association(:inbox).loaded? &&
          record.conversation.association(:communication_thread).loaded?
      end
    ).and_call_original

    payload = JSON.parse(service.execute(appointment_id: appointment.id))

    expect(payload['appointment']).to include(
      'id' => appointment.id,
      'resource_id' => resource.id,
      'contact_id' => contact.id,
      'service_id' => scheduling_service.id,
      'duration_min' => appointment.duration_min
    )
  end
end
