require 'rails_helper'

RSpec.describe Captain::Tools::CreateAppointmentTool, type: :model do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:tool) { described_class.new(assistant) }

  before do
    account.enable_features!('scheduling')
  end

  def stub_provider_availability
    result = Integrations::Medelement::ResourceAvailabilityService::Result.new(
      status: 'fresh', checked_at: Time.current, slots: [{}], reason: nil
    )
    service = instance_double(Integrations::Medelement::ResourceAvailabilityService, perform: result)
    allow(Integrations::Medelement::ResourceAvailabilityService).to receive(:new).and_return(service)
  end

  def acknowledge_write_for_tool!(appointment)
    command = appointment.medelement_provider_command_receipt
    command.update!(
      provider_patient_code: 'patient-1', provider_reception_code: 'reception-1',
      execution_state: command.execution_state.merge(
        'write_provider_patient_code' => 'patient-1', 'write_provider_reception_code' => 'reception-1'
      )
    )
  end

  it 'returns a typed nonretryable tool failure instead of confirming an unknown provider booking' do
    contact = create(:contact, account: account)
    conversation = create(:conversation, account: account, contact: contact)
    create(:captain_inbox, inbox: conversation.inbox, captain_assistant: assistant)
    appointment = create(:scheduling_appointment, account: account, contact: contact, conversation: conversation)
    operations = instance_double(Captain::Tools::Operations::AppointmentOperations, create_appointment: appointment)
    outcome = instance_double(Captain::Tools::ProviderBookingOutcomeService)
    allow(outcome).to receive(:perform).and_raise(
      Scheduling::Error.new(code: 'MEDELEMENT_BOOKING_UNKNOWN', message: 'Staff verification required', status: :unprocessable_content)
    )
    allow(tool).to receive(:operations).and_return(operations)
    allow(Captain::Tools::ProviderBookingOutcomeService).to receive(:new).and_return(outcome)
    incoming = create(:message, conversation: conversation, message_type: :incoming)
    state = {
      conversation: { id: conversation.id },
      captain_response_fence: {
        control_generation: conversation.current_captain_control_generation,
        status_transition_id: conversation.status_transitions.maximum(:id).to_i,
        last_message_id: incoming.id
      }
    }

    result = Captain::ToolResult.normalize(tool.perform(Struct.new(:state).new(state), resource_id: 1, starts_at: Time.current.iso8601))

    expect(result).to include(success: false, retryable: false, data: { 'success' => false, 'reason' => 'staff_will_help' })
    expect(conversation.messages.outgoing.where(private: false)).to be_empty
    expect(conversation.reload.status).to eq('open')
    expect(conversation.current_captain_control_state).to eq('human')
    expect(conversation.messages.outgoing.where(private: true).last.content).to include('Medelement')
  end

  it 'hands off a provider booking when receipt verification raises unexpectedly after local creation' do
    contact = create(:contact, account: account)
    conversation = create(:conversation, account: account, contact: contact, status: :pending)
    create(:captain_inbox, inbox: conversation.inbox, captain_assistant: assistant)
    appointment = create(
      :scheduling_appointment, account: account, contact: contact, conversation: conversation,
                               custom_attributes: { Integrations::Medelement::AppointmentProviderStatus::ATTRIBUTE_KEY => 'pending' }
    )
    operations = instance_double(Captain::Tools::Operations::AppointmentOperations, create_appointment: appointment)
    allow(tool).to receive(:operations).and_return(operations)
    allow(Captain::Tools::ProviderBookingOutcomeService).to receive(:new).and_raise(StandardError, 'provider receipt read failed')
    incoming = create(:message, conversation: conversation, message_type: :incoming)
    state = {
      conversation: { id: conversation.id },
      captain_response_fence: {
        control_generation: conversation.current_captain_control_generation,
        status_transition_id: conversation.status_transitions.maximum(:id).to_i,
        last_message_id: incoming.id
      }
    }

    result = Captain::ToolResult.normalize(tool.perform(Struct.new(:state).new(state), resource_id: 1, starts_at: Time.current.iso8601))

    expect(result).to include(success: false, retryable: false)
    expect(conversation.reload.status).to eq('open')
    expect(conversation.messages.outgoing.where(private: false)).to be_empty
    expect(conversation.messages.outgoing.where(private: true).count).to eq(1)
  end

  it 'recovers a saved provider booking after a receipt error and does not create it twice on retry' do
    allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
    resource = create(:scheduling_resource, account: account, custom_attributes: { 'medelement_specialist_code' => 'specialist-1' })
    contact = create(:contact, account: account)
    conversation = create(:conversation, account: account, contact: contact, status: :pending)
    create(:captain_inbox, inbox: conversation.inbox, captain_assistant: assistant)
    appointment = create(
      :scheduling_appointment, account: account, resource: resource, contact: contact, conversation: conversation,
                               custom_attributes: { Integrations::Medelement::AppointmentProviderStatus::ATTRIBUTE_KEY => 'provider_status_unknown' }
    )
    upsert = instance_double(Scheduling::Appointments::UpsertService, persisted_appointment: appointment)
    expect(upsert).to receive(:perform).once.and_raise(
      Scheduling::Error.new(code: 'MEDELEMENT_COMMAND_RECEIPT_UNAVAILABLE', message: 'Receipt unavailable', status: :service_unavailable)
    )
    allow(Scheduling::Appointments::UpsertService).to receive(:new).and_return(upsert)
    incoming = create(:message, conversation: conversation, message_type: :incoming)
    state = {
      conversation: { id: conversation.id },
      captain_response_fence: {
        control_generation: conversation.current_captain_control_generation,
        status_transition_id: conversation.status_transitions.maximum(:id).to_i,
        last_message_id: incoming.id
      }
    }
    context = Struct.new(:state).new(state)
    input = { resource_id: resource.id, starts_at: appointment.starts_at.iso8601 }

    first = Captain::ToolResult.normalize(tool.perform(context, **input))
    second = Captain::ToolResult.normalize(tool.perform(context, **input))

    expect(first).to include(success: false, retryable: false, data: { 'success' => false, 'reason' => 'staff_will_help' })
    expect(second).to include(success: false, retryable: false)
    expect(conversation.reload.status).to eq('open')
    expect(conversation.messages.outgoing.where(private: true).count).to eq(1)
    expect(account.scheduling_appointments.where(conversation: conversation).count).to eq(1)
  end

  it 'returns a typed superseded error and hands an acknowledged orphan to the original conversation' do
    contact = create(:contact, account: account)
    conversation = create(:conversation, account: account, contact: contact, status: :pending)
    create(:captain_inbox, inbox: conversation.inbox, captain_assistant: assistant)
    resource = create(:scheduling_resource, account: account, custom_attributes: { 'medelement_specialist_code' => 'specialist-1' })
    appointment = create(:scheduling_appointment, account: account, contact: contact, conversation: conversation, resource: resource)
    command = Integrations::Medelement::ProviderCommand.create!(
      account: account, appointment: appointment, contact: contact, operation: 'create_reception', status: 'processing',
      idempotency_key: SecureRandom.uuid, company_cabinet_code: 'cab-1', provider_patient_code: 'patient-1',
      provider_reception_code: 'reception-1', desired_starts_at: appointment.starts_at, desired_ends_at: appointment.ends_at,
      execution_state: {
        'write_provider_reception_code' => 'reception-1', 'request_fingerprint' => 'booking-fingerprint',
        'dispatch_identity' => 'booking-dispatch',
        'request_snapshot' => {
          'actor' => { 'type' => 'Captain::Assistant', 'id' => assistant.id },
          'account_id' => account.id, 'appointment_id' => appointment.id, 'contact_id' => contact.id,
          'conversation_id' => conversation.id,
          'reception' => {
            'resource_id' => resource.id, 'destination_starts_at' => appointment.starts_at.iso8601,
            'destination_ends_at' => appointment.ends_at.iso8601, 'nomenclature_codes' => []
          }
        }
      }
    )
    appointment.update!(custom_attributes: appointment.custom_attributes.merge(
      Integrations::Medelement::AppointmentProviderStatus::ATTRIBUTE_KEY => 'pending',
      Integrations::Medelement::AppointmentProviderStatus::COMMAND_ID_KEY => command.id
    ))
    appointment.medelement_provider_command_receipt = command
    replacement = create(:scheduling_resource, account: account)
    appointment.update!(resource: replacement)
    operations = instance_double(Captain::Tools::Operations::AppointmentOperations, create_appointment: appointment)
    allow(tool).to receive(:operations).and_return(operations)
    incoming = create(:message, conversation: conversation, message_type: :incoming)
    state = {
      conversation: { id: conversation.id },
      captain_response_fence: {
        control_generation: conversation.current_captain_control_generation,
        status_transition_id: conversation.status_transitions.maximum(:id).to_i,
        last_message_id: incoming.id
      }
    }
    context = Struct.new(:state).new(state)

    expect(Integrations::Medelement::ProviderCommandJob).not_to receive(:perform_later)
    result = Captain::ToolResult.normalize(tool.perform(context, resource_id: resource.id, starts_at: appointment.starts_at.iso8601))

    expect(result).to include(success: false, retryable: false, data: { 'success' => false, 'reason' => 'staff_will_help' })
    expect(conversation.reload.status).to eq('open')
    expect(conversation.messages.outgoing.where(private: false)).to be_empty
    expect(conversation.messages.outgoing.where(private: true).count).to eq(1)
    expect(conversation.messages.outgoing.where(private: true).last.additional_attributes['medelement_provider_command_id']).to eq(command.id)
    expect(appointment.reload.resource_id).to eq(replacement.id)
  end

  it 'does not hand off an ordinary local scheduling validation error' do
    conversation = create(:conversation, account: account, status: :pending)
    operations = instance_double(Captain::Tools::Operations::AppointmentOperations)
    allow(operations).to receive(:create_appointment).and_raise(
      Scheduling::Error.new(code: 'RESOURCE_UNAVAILABLE', message: 'No slot', status: :unprocessable_content)
    )
    allow(tool).to receive(:operations).and_return(operations)
    context = Struct.new(:state).new({ conversation: { id: conversation.id } })

    result = Captain::ToolResult.normalize(tool.perform(context, resource_id: 1, starts_at: Time.current.iso8601))

    expect(result).to include(success: false, data: { 'success' => false, 'reason' => 'validation_error' })
    expect(conversation.reload.status).to eq('pending')
    expect(conversation.messages.outgoing).to be_empty
  end

  it 'returns only patient booking fields in the doctors local time and marks the source' do
    resource = create(:scheduling_resource, account: account, timezone: 'Asia/Almaty', slot_duration_min: 30)
    contact = create(:contact, account: account)
    conversation = create(:conversation, account: account, contact: contact)
    scheduling_service = create(:scheduling_service, account: account, duration_min: 30)
    create(:scheduling_work_rule, resource: resource, weekday: 1, start_minute: 9 * 60, end_minute: 18 * 60)
    create(:scheduling_service_price, account: account, service: scheduling_service, resource: resource, active: true, price: 20_000)
    tool_context = Struct.new(:state).new({ conversation: { id: conversation.id }, contact: { id: contact.id } })

    payload = JSON.parse(tool.perform(tool_context, resource_id: resource.id, service_id: scheduling_service.id,
                                                    starts_at: Time.zone.parse('2026-04-20 09:00:00 +0500').iso8601,
                                                    duration_min: 30, custom_attributes: { source: 'agent' }))

    expect(payload).to eq(
      'success' => true, 'appointment_id' => payload.fetch('appointment_id'),
      'doctor_name' => resource.name, 'local_date' => '20.04.2026', 'local_time' => '09:00', 'status' => 'created'
    )
    expect(account.scheduling_appointments.find(payload.fetch('appointment_id'))).to have_attributes(source: 'captain')
  end

  it 'exposes custom_attributes as an object parameter' do
    expect(described_class.parameters[:custom_attributes].type).to eq('object')
  end

  it 'instructs the agent to confirm only a successful booking tool result' do
    expect(tool.description).to include('reception ID', 'do not claim success or repeat the create call')
  end

  it 'keeps the provider command internally while showing only the booking result' do
    stub_provider_availability
    hook_settings = attributes_for(:integrations_hook, :medelement)[:settings].merge('write_enabled' => true)
    create(:integrations_hook, :medelement, account: account, settings: hook_settings)
    resource = create(
      :scheduling_resource,
      account: account,
      timezone: 'Asia/Almaty',
      slot_duration_min: 30,
      custom_attributes: {
        'medelement_specialist_code' => 'specialist-1',
        'medelement_cabinets' => [{ 'companyCabinetCode' => 'cabinet-1' }]
      }
    )
    contact = create(:contact, account: account, name: 'Aruzhan', last_name: 'Testova', phone_number: '+77011234567')
    conversation = create(:conversation, account: account, contact: contact)
    scheduling_service = create(:scheduling_service, account: account, duration_min: 30,
                                                     custom_attributes: { 'medelement_nomenclature_code' => 'service-1' })
    create(:scheduling_work_rule, resource: resource, weekday: 1, start_minute: 9 * 60, end_minute: 18 * 60)
    create(:scheduling_service_price, account: account, service: scheduling_service, resource: resource, active: true, price: 20_000)
    tool_context = Struct.new(:state).new({ conversation: { id: conversation.id }, contact: { id: contact.id } })

    arguments = {
      resource_id: resource.id,
      service_id: scheduling_service.id,
      starts_at: Time.zone.parse('2026-04-20 09:00:00 +0500').iso8601,
      duration_min: 30,
      custom_attributes: { medelement_cabinet_code: 'cabinet-1' }
    }
    allow(Captain::Tools::ProviderBookingOutcomeService).to receive(:new).and_wrap_original do |method, **kwargs|
      acknowledge_write_for_tool!(kwargs.fetch(:appointment))
      method.call(**kwargs)
    end
    payload = JSON.parse(tool.perform(tool_context, **arguments))

    appointment = account.scheduling_appointments.find(payload.fetch('appointment_id'))
    allow(Captain::ToolExecutionIdempotency).to receive(:fetch_record).and_return(appointment.reload)
    replay_payload = JSON.parse(tool.perform(tool_context, **arguments))
    expect(payload).to eq(
      'success' => true, 'appointment_id' => appointment.id, 'doctor_name' => resource.name,
      'local_date' => '20.04.2026', 'local_time' => '09:00', 'status' => 'created'
    )
    expect(replay_payload).to eq(payload)
    command = Integrations::Medelement::ProviderCommand.find_by!(appointment_id: appointment.id, operation: 'create_reception')
    expect(command.request_snapshot.dig('actor', 'type')).to eq('Captain::Assistant')
    expect(Integrations::Medelement::ProviderCommand.where(account_id: account.id, operation: 'create_reception').count).to eq(1)
    expect(conversation.messages.outgoing.where(private: false)).to be_empty
  end
end
