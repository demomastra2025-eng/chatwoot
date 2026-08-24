require 'rails_helper'

RSpec.describe Captain::Tools::Copilot::CreateAppointmentService do
  let(:account) { create(:account) }
  let(:user) { create(:user, :administrator, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:contact) { create(:contact, account: account, name: 'Aruzhan', phone_number: '+77000000000') }
  let(:conversation) { create(:conversation, account: account, contact: contact) }
  let(:copilot_thread) { create(:captain_copilot_thread, account: account, user: user, assistant: assistant) }
  let(:service) { described_class.new(assistant, user: user, conversation: conversation, copilot_thread: copilot_thread) }
  let(:resource) { create(:scheduling_resource, account: account, timezone: 'Asia/Almaty', slot_duration_min: 30) }
  let(:consultation) { create(:scheduling_service, account: account, name: 'Consultation', duration_min: 45, base_price: 20_000) }
  let(:starts_at) { Time.zone.parse('2026-04-20 09:00:00 +0500') }

  before do
    account.enable_features!('scheduling')
    create(:scheduling_work_rule, resource: resource, weekday: 1, start_minute: 9 * 60, end_minute: 18 * 60)
    create(:scheduling_service_price, account: account, service: consultation, resource: resource, active: true, price: 20_000)
  end

  describe '#execute' do
    it 'creates an appointment from the selected service duration and returns a structured payload' do
      payload = JSON.parse(
        execute_confirmed(
          resource_id: resource.id,
          starts_at: starts_at.iso8601,
          service_id: consultation.id,
          client_comment: 'Needs a morning slot',
          custom_attributes: { source: 'captain', channel: 'telegram' }
        )
      )

      appointment = account.scheduling_appointments.order(:id).last

      expect(payload).to include(
        'action' => 'create_appointment',
        'appointment_id' => appointment.id,
        'status' => appointment.status,
        'resource_id' => resource.id,
        'contact_id' => contact.id,
        'service_id' => consultation.id,
        'starts_at' => payload.dig('appointment', 'starts_at'),
        'ends_at' => payload.dig('appointment', 'ends_at')
      )
      expect(payload['appointment']).to include(
        'id' => appointment.id,
        'resource_id' => resource.id,
        'contact_id' => contact.id,
        'service_id' => consultation.id,
        'duration_min' => 45,
        'client_comment' => 'Needs a morning slot'
      )
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

    it 'exposes custom_attributes as an object parameter' do
      expect(described_class.parameters[:custom_attributes].type).to eq(:object)
    end

    it 'falls back to the specialist slot duration when no service or duration is provided' do
      execute_confirmed(resource_id: resource.id, starts_at: starts_at.iso8601)

      appointment = account.scheduling_appointments.order(:id).last

      expect(appointment.duration_min).to eq(30)
      expect(appointment.ends_at).to eq(starts_at + 30.minutes)
    end

    it 'creates a Medelement appointment from structured contact custom names' do
      resource.update!(
        custom_attributes: {
          'medelement_specialist_code' => 'specialist-1',
          'medelement_cabinets' => [{ 'companyCabinetCode' => 'cabinet-1' }]
        }
      )
      contact.update!(
        name: 'Жандаулет Гусман',
        last_name: nil,
        phone_number: ['+7', '700', '000', '0001'].join,
        custom_attributes: contact.custom_attributes.merge(
          'medelement_first_name' => 'Жандаулет',
          'medelement_last_name' => 'Гусман',
          'iin' => '940720300129'
        )
      )

      execute_confirmed(
        resource_id: resource.id,
        starts_at: starts_at.iso8601,
        duration_min: 30,
        appointment_type: 'primary',
        custom_attributes: { 'medelement_cabinet_code' => 'cabinet-1' }
      )

      expect(account.scheduling_appointments.order(:id).last).to have_attributes(
        client_first_name: 'Жандаулет',
        client_last_name: 'Гусман',
        client_identifier: '940720300129',
        appointment_type: 'primary'
      )
    end
  end

  def execute_confirmed(**arguments)
    first_result = service.execute(**arguments)
    first_payload = JSON.parse(first_result)
    return first_result unless first_payload.dig('data', 'confirmation_required')

    confirmation_token = copilot_thread.copilot_messages.assistant_thinking.last.message.dig('confirmation_gate', 'confirmation_token')

    create(
      :captain_copilot_message,
      account: account,
      copilot_thread: copilot_thread,
      message_type: 'user',
      message: { 'content' => "Подтверждаю #{confirmation_token}" }
    )

    service.execute(**arguments)
  end
end
