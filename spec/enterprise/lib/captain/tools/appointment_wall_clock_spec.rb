require 'rails_helper'

RSpec.describe 'Captain appointment calendar clocks', type: :model do
  include ActiveSupport::Testing::TimeHelpers

  around { |example| travel_to(Time.utc(2026, 4, 19, 12)) { example.run } }

  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:contact) { create(:contact, account: account) }
  let(:conversation) { create(:conversation, account: account, contact: contact) }
  let(:resource) { create(:scheduling_resource, account: account, timezone: 'Asia/Almaty', slot_duration_min: 30) }
  let(:service) { create(:scheduling_service, account: account, duration_min: 30) }
  let(:context) { Struct.new(:state).new({ conversation: { id: conversation.id }, contact: { id: contact.id } }) }

  before do
    account.enable_features!('scheduling')
    create(:scheduling_work_rule, resource: resource, weekday: 1, start_minute: 9 * 60, end_minute: 18 * 60)
    create(:scheduling_service_price, account: account, service: service, resource: resource, active: true, price: 20_000)
  end

  it 'creates at 14:00 local and reports the same confirmed calendar clock' do
    result = JSON.parse(Captain::Tools::CreateAppointmentTool.new(assistant).perform(
      context, resource_id: resource.id, service_id: service.id, starts_at: '2026-04-20T14:00', duration_min: 30
    ))
    expect(result).to include('success' => true, 'local_time' => '14:00')
    saved = account.scheduling_appointments.find(result.fetch('appointment_id'))
    expect(saved.starts_at).to eq(Time.utc(2026, 4, 20, 9))
    expect(saved.ends_at).to eq(Time.utc(2026, 4, 20, 9, 30))
  end

  it 'moves the identified appointment using the requested local clock without model conversion' do
    appointment = create(:scheduling_appointment, account: account, resource: resource, service: service,
                                                contact: contact, conversation: conversation,
                                                starts_at: Time.utc(2026, 4, 20, 5), ends_at: Time.utc(2026, 4, 20, 5, 30))
    result = JSON.parse(Captain::Tools::UpdateAppointmentTool.new(assistant).perform(
      context, appointment_id: appointment.id, starts_at: '2026-04-20T14:00', duration_min: 30
    ))
    expect(result).to include('success' => true, 'local_time' => '14:00')
    expect(appointment.reload.starts_at).to eq(Time.utc(2026, 4, 20, 9))
    expect(appointment.ends_at).to eq(Time.utc(2026, 4, 20, 9, 30))
  end
end
