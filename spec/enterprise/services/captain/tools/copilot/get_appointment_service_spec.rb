require 'rails_helper'

RSpec.describe Captain::Tools::Copilot::GetAppointmentService do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:service) { described_class.new(assistant, user: user) }

  before do
    account.enable_features!('scheduling')
  end

  it 'returns a normalized appointment payload' do
    resource = create(:scheduling_resource, account: account, name: 'Dr. Aida')
    contact = create(:contact, account: account, name: 'Aruzhan')
    scheduling_service = create(:scheduling_service, account: account, name: 'Consultation', duration_min: 30)
    appointment = create(:scheduling_appointment, account: account, resource: resource, contact: contact, service: scheduling_service)

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
