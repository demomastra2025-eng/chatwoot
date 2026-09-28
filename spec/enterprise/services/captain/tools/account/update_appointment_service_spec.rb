require 'rails_helper'

RSpec.describe Captain::Tools::Account::UpdateAppointmentService do
  let(:account) { create(:account) }
  let(:user) { create(:user, :administrator, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:contact) { create(:contact, account: account, name: 'Aruzhan', phone_number: '+77000000000') }
  let(:conversation) { create(:conversation, account: account, contact: contact) }
  let(:copilot_thread) { create(:captain_copilot_thread, account: account, user: user, assistant: assistant) }
  let(:service) { described_class.new(assistant, user: user, conversation: conversation, copilot_thread: copilot_thread) }
  let(:resource) { create(:scheduling_resource, account: account, timezone: 'Asia/Almaty', slot_duration_min: 30) }
  let(:new_resource) { create(:scheduling_resource, account: account, timezone: 'Asia/Almaty', slot_duration_min: 20) }
  let(:consultation) { create(:scheduling_service, account: account, name: 'Consultation', duration_min: 45, base_price: 20_000) }
  let(:follow_up) { create(:scheduling_service, account: account, name: 'Follow-up', duration_min: 20, base_price: 10_000) }
  let!(:appointment) do
    create(
      :scheduling_appointment,
      account: account,
      conversation: conversation,
      contact: contact,
      resource: resource,
      service: consultation,
      starts_at: Time.zone.parse('2026-04-20 09:00:00 +0500'),
      ends_at: Time.zone.parse('2026-04-20 09:45:00 +0500'),
      duration_min: 45,
      custom_attributes: { 'source' => 'captain' }
    )
  end
  let(:updated_start) { Time.zone.parse('2026-04-20 11:00:00 +0500') }

  before do
    account.enable_features!('scheduling')
    create(:scheduling_work_rule, resource: resource, weekday: 1, start_minute: 9 * 60, end_minute: 18 * 60)
    create(:scheduling_work_rule, resource: new_resource, weekday: 1, start_minute: 9 * 60, end_minute: 18 * 60)
    create(:scheduling_service_price, account: account, service: consultation, resource: resource, active: true, price: 20_000)
    create(:scheduling_service_price, account: account, service: follow_up, resource: new_resource, active: true, price: 10_000)
  end

  describe '#execute' do
    it 'recomputes ends_at from duration and returns a structured payload' do
      payload = JSON.parse(
        execute_confirmed(
          resource_id: new_resource.id,
          service_id: follow_up.id,
          starts_at: updated_start.iso8601,
          custom_attributes: { source: 'captain', rescheduled_by: 'agent' }
        )
      )

      appointment.reload

      expect(payload).to include(
        'action' => 'update_appointment',
        'appointment_id' => appointment.id,
        'status' => appointment.status,
        'resource_id' => new_resource.id,
        'contact_id' => contact.id,
        'service_id' => follow_up.id,
        'starts_at' => payload.dig('appointment', 'starts_at'),
        'ends_at' => payload.dig('appointment', 'ends_at')
      )
      expect(payload['appointment']).to include(
        'id' => appointment.id,
        'resource_id' => new_resource.id,
        'service_id' => follow_up.id,
        'duration_min' => 20
      )
      expect(payload['appointment']).not_to include('payment_status', 'prepaid_amount', 'settlement_amount', 'payments', 'expense')
      expect(appointment).to have_attributes(
        resource_id: new_resource.id,
        service_id: follow_up.id,
        duration_min: 20,
        starts_at: updated_start,
        ends_at: updated_start + 20.minutes
      )
      expect(appointment.custom_attributes).to include(
        'source' => 'captain',
        'rescheduled_by' => 'agent',
        'service_ids' => [follow_up.id]
      )
    end

    it 'exposes custom_attributes as an object parameter' do
      expect(described_class.parameters[:custom_attributes].type).to eq(:object)
    end

    it 'updates the explicitly selected appointment when the conversation has multiple appointments' do
      other = create(
        :scheduling_appointment,
        account: account,
        conversation: conversation,
        contact: contact,
        resource: resource,
        starts_at: appointment.starts_at + 1.day
      )

      result = execute_confirmed(appointment_id: appointment.id, client_comment: 'Selected appointment')

      expect(result).not_to start_with('ERROR:')
      expect(appointment.reload.client_comment).to eq('Selected appointment')
      expect(other.reload.client_comment).to be_nil
    end

    it 'returns the move command receipt for a confirmed employee update' do
      availability = Integrations::Medelement::ResourceAvailabilityService::Result.new(
        status: 'fresh', checked_at: Time.current, slots: [{}], reason: nil
      )
      allow(Integrations::Medelement::ResourceAvailabilityService).to receive(:new)
        .and_return(instance_double(Integrations::Medelement::ResourceAvailabilityService, perform: availability))
      settings = attributes_for(:integrations_hook, :medelement)[:settings].merge('write_enabled' => true)
      create(:integrations_hook, :medelement, account: account, settings: settings)
      contact.update!(
        name: 'Aruzhan', last_name: 'Testova', phone_number: ['+7', '700', '000', '0001'].join,
        custom_attributes: contact.custom_attributes.merge(
          'medelement_first_name' => 'Aruzhan', 'medelement_last_name' => 'Testova',
          'medelement_middle_name' => 'Serikovna', 'medelement_patient_code' => 'patient-1'
        )
      )
      resource.update!(
        custom_attributes: {
          'medelement_specialist_code' => 'specialist-1',
          'medelement_cabinets' => [{ 'companyCabinetCode' => 'cabinet-1' }]
        }
      )
      consultation.update!(custom_attributes: { 'medelement_nomenclature_code' => 'service-1' })
      appointment.update!(
        external_ref: 'medelement:reception:reception-1',
        custom_attributes: { 'medelement_reception_code' => 'reception-1', 'medelement_cabinet_code' => 'cabinet-1' }
      )

      result = execute_confirmed(appointment_id: appointment.id, starts_at: updated_start.iso8601)
      raise result if result.start_with?('ERROR:')

      payload = JSON.parse(result)
      receipt = payload.fetch('provider_command_receipt')
      expect(receipt).to include('appointment_id' => appointment.id, 'expected_operation' => 'move_reception', 'linked' => true)
      expect(receipt.fetch('command')).to include(
        'operation' => 'move_reception', 'requested_by' => { 'type' => 'User', 'id' => user.id }
      )
      expect(Integrations::Medelement::ProviderCommand.find(receipt.dig('command', 'id')).appointment_id).to eq(appointment.id)
    end

    it 'returns an error when explicit ends_at conflicts with duration_min' do
      result = execute_confirmed(
        starts_at: updated_start.iso8601,
        ends_at: (updated_start + 45.minutes).iso8601,
        duration_min: 20
      )

      expect(result).to start_with('ERROR:')
      expect(result).to include('duration_min does not match ends_at')
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
