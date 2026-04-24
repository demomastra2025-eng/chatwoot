require 'rails_helper'

RSpec.describe Captain::Tools::Copilot::CreateAppointmentService do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:contact) { create(:contact, account: account, name: 'Aruzhan', phone_number: '+77000000000') }
  let(:conversation) { create(:conversation, account: account, contact: contact) }
  let(:service) { described_class.new(assistant, user: user, conversation: conversation) }
  let(:resource) { create(:scheduling_resource, account: account, timezone: 'Asia/Almaty', slot_duration_min: 30) }
  let(:consultation) { create(:scheduling_service, account: account, name: 'Consultation', duration_min: 45, base_price: 20_000) }
  let(:starts_at) { Time.zone.parse('2026-04-20 09:00:00 +0500') }

  before do
    account.enable_features!('scheduling')
    create(:scheduling_work_rule, resource: resource, weekday: 1, start_minute: 9 * 60, end_minute: 18 * 60)
    create(:scheduling_service_price, account: account, service: consultation, resource: resource, active: true, price: 20_000)
  end

  describe '#execute' do
    it 'creates an appointment from the selected service duration without requiring ends_at' do
      service.execute(
        resource_id: resource.id,
        starts_at: starts_at.iso8601,
        service_id: consultation.id,
        client_comment: 'Needs a morning slot',
        custom_attributes: { 'source' => 'captain', 'channel' => 'telegram' }
      )

      appointment = account.scheduling_appointments.order(:id).last

      expect(appointment).to have_attributes(
        resource_id: resource.id,
        service_id: consultation.id,
        conversation_id: conversation.id,
        contact_id: contact.id,
        duration_min: 45,
        starts_at: starts_at,
        ends_at: starts_at + 45.minutes,
        client_comment: 'Needs a morning slot'
      )
      expect(appointment.custom_attributes).to include(
        'source' => 'captain',
        'channel' => 'telegram',
        'service_ids' => [consultation.id]
      )
    end

    it 'falls back to the specialist slot duration when no service or duration is provided' do
      service.execute(resource_id: resource.id, starts_at: starts_at.iso8601)

      appointment = account.scheduling_appointments.order(:id).last

      expect(appointment.duration_min).to eq(30)
      expect(appointment.ends_at).to eq(starts_at + 30.minutes)
    end
  end
end
