require 'rails_helper'

RSpec.describe Captain::Tools::UpdateAppointmentTool, type: :model do
  include ActiveSupport::Testing::TimeHelpers
  include_context 'with a fake provider write wait clock'

  around { |example| travel_to(Time.utc(2026, 4, 19, 12)) { example.run } }

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

  it 'returns normalized update_appointment payload' do
    resource = create(:scheduling_resource, account: account, timezone: 'Asia/Almaty', slot_duration_min: 30)
    new_resource = create(:scheduling_resource, account: account, timezone: 'Asia/Almaty', slot_duration_min: 20)
    contact = create(:contact, account: account)
    conversation = create(:conversation, account: account, contact: contact)
    scheduling_service = create(:scheduling_service, account: account, duration_min: 30)
    new_service = create(:scheduling_service, account: account, duration_min: 20)
    create(:scheduling_work_rule, resource: resource, weekday: 1, start_minute: 9 * 60, end_minute: 18 * 60)
    create(:scheduling_work_rule, resource: new_resource, weekday: 1, start_minute: 9 * 60, end_minute: 18 * 60)
    create(:scheduling_service_price, account: account, service: scheduling_service, resource: resource, active: true, price: 20_000)
    create(:scheduling_service_price, account: account, service: new_service, resource: new_resource, active: true, price: 10_000)
    appointment = create(:scheduling_appointment, account: account, resource: resource, contact: contact, service: scheduling_service,
                                                  conversation_id: conversation.id)
    tool_context = Struct.new(:state).new({ conversation: { id: conversation.id }, appointment: { id: appointment.id }, contact: { id: contact.id } })

    payload = JSON.parse(tool.perform(tool_context, resource_id: new_resource.id, service_id: new_service.id,
                                                    starts_at: Time.zone.parse('2026-04-20 11:00:00 +0500').iso8601,
                                                    custom_attributes: { source: 'agent' }))

    expect(payload).to eq(
      'success' => true, 'appointment_id' => appointment.id, 'doctor_name' => new_resource.name,
      'local_date' => '20.04.2026', 'local_time' => '11:00', 'status' => 'updated'
    )
    expect(appointment.reload).to have_attributes(resource_id: new_resource.id, service_id: new_service.id)
    expect(appointment.custom_attributes).to include('source' => 'agent')
  end

  describe 'a move to the time the appointment already has' do
    let(:resource) { create(:scheduling_resource, account: account, timezone: 'Asia/Almaty', slot_duration_min: 30) }
    let(:contact) { create(:contact, account: account) }
    let(:conversation) { create(:conversation, account: account, contact: contact) }
    let(:starts_at) { Time.zone.parse('2026-04-20 11:00:00 +0500') }
    let!(:appointment) do
      create(:scheduling_appointment, account: account, resource: resource, contact: contact, conversation_id: conversation.id,
                                      starts_at: starts_at, ends_at: starts_at + 30.minutes, duration_min: 30)
    end
    let(:tool_context) do
      Struct.new(:state).new({ conversation: { id: conversation.id }, appointment: { id: appointment.id }, contact: { id: contact.id } })
    end

    before { create(:scheduling_work_rule, resource: resource, weekday: 1, start_minute: 9 * 60, end_minute: 18 * 60) }

    it 'is answered as unchanged, and nothing is saved or sent to the provider' do
      expect(Scheduling::Appointments::UpsertService).not_to receive(:new)

      payload = JSON.parse(tool.perform(tool_context, appointment_id: appointment.id, starts_at: starts_at.iso8601))

      expect(payload).to include('success' => true, 'appointment_id' => appointment.id, 'local_date' => '20.04.2026', 'local_time' => '11:00',
                                 'status' => 'unchanged',
                                 'note' => "The appointment is already at 20.04.2026 11:00 with #{resource.name}; nothing was changed.")
      expect(appointment.reload.starts_at).to eq(starts_at)
    end

    it 'is a success of the call and no mutation: the tool result says so for the monitoring event' do
      payload = tool.perform(tool_context, appointment_id: appointment.id, starts_at: starts_at.iso8601)

      expect(Captain::ToolResult.no_change?(payload)).to be(true)
    end

    it 'is also unchanged when the call names the service the appointment already has' do
      expect(Scheduling::Appointments::UpsertService).not_to receive(:new)

      payload = JSON.parse(tool.perform(tool_context, appointment_id: appointment.id, service_id: appointment.service_id,
                                                      starts_at: starts_at.iso8601))

      expect(payload).to include('success' => true, 'status' => 'unchanged')
    end

    it 'is also unchanged when the call names the specialist the appointment already has' do
      expect(Scheduling::Appointments::UpsertService).not_to receive(:new)

      payload = JSON.parse(tool.perform(tool_context, appointment_id: appointment.id, resource_id: resource.id, starts_at: starts_at.iso8601))

      expect(payload).to include('success' => true, 'status' => 'unchanged')
    end

    it 'is still a change when anything else in the call differs: another time, or a new comment next to the same time' do
      payload = JSON.parse(tool.perform(tool_context, appointment_id: appointment.id, starts_at: starts_at.iso8601, client_comment: 'Bring the card'))

      expect(payload).to include('success' => true, 'status' => 'updated')
      expect(appointment.reload.client_comment).to eq('Bring the card')
    end

    it 'leaves a cancelled appointment to the normal path, which says why it cannot be changed' do
      appointment.update!(status: 'cancelled')

      payload = JSON.parse(tool.perform(tool_context, appointment_id: appointment.id, starts_at: starts_at.iso8601))

      expect(payload['status']).not_to eq('unchanged')
    end
  end

  it 'exposes custom_attributes as an object parameter' do
    expect(described_class.parameters[:custom_attributes].type).to eq('object')
  end

  it 'updates the explicitly selected appointment when the conversation has multiple appointments' do
    resource = create(:scheduling_resource, account: account)
    contact = create(:contact, account: account)
    conversation = create(:conversation, account: account, contact: contact)
    selected = create(
      :scheduling_appointment,
      account: account,
      resource: resource,
      contact: contact,
      conversation: conversation,
      starts_at: 2.days.from_now
    )
    other = create(
      :scheduling_appointment,
      account: account,
      resource: resource,
      contact: contact,
      conversation: conversation,
      starts_at: 3.days.from_now
    )
    tool_context = Struct.new(:state).new({ conversation: { id: conversation.id }, appointment: { id: selected.id } })

    result = tool.perform(tool_context, appointment_id: selected.id, client_comment: 'Selected appointment')

    expect(result).not_to start_with('ERROR:')
    expect(selected.reload.client_comment).to eq('Selected appointment')
    expect(other.reload.client_comment).to be_nil
  end

  it 'does not fall back when the explicit appointment belongs to another conversation' do
    resource = create(:scheduling_resource, account: account)
    conversation = create(:conversation, account: account)
    other_conversation = create(:conversation, account: account)
    linked = create(:scheduling_appointment, account: account, resource: resource, conversation: conversation)
    unauthorized = create(:scheduling_appointment, account: account, resource: resource, conversation: other_conversation)
    tool_context = Struct.new(:state).new({ conversation: { id: conversation.id } })

    result = tool.perform(tool_context, appointment_id: unauthorized.id, client_comment: 'Must not be applied')

    expect(JSON.parse(result)).to eq('success' => false, 'reason' => 'not_found', 'error_class' => 'business')
    expect(linked.reload.client_comment).to be_nil
    expect(unauthorized.reload.client_comment).to be_nil
  end

  it 'rejects an explicit appointment from another account before mutation' do
    other_account = create(:account)
    resource = create(:scheduling_resource, account: account)
    foreign_resource = create(:scheduling_resource, account: other_account)
    conversation = create(:conversation, account: account)
    linked = create(:scheduling_appointment, account: account, resource: resource, conversation: conversation)
    foreign = create(:scheduling_appointment, account: other_account, resource: foreign_resource)
    tool_context = Struct.new(:state).new({ conversation: { id: conversation.id } })

    result = tool.perform(tool_context, appointment_id: foreign.id, client_comment: 'Must not be applied')

    expect(JSON.parse(result)).to eq('success' => false, 'reason' => 'not_found', 'error_class' => 'business')
    expect(linked.reload.client_comment).to be_nil
    expect(foreign.reload.client_comment).to be_nil
  end

  it 'rejects explicitly provided invalid appointment IDs without falling back to the only appointment' do
    resource = create(:scheduling_resource, account: account)
    conversation = create(:conversation, account: account)
    appointment = create(:scheduling_appointment, account: account, resource: resource, conversation: conversation)
    tool_context = Struct.new(:state).new({ conversation: { id: conversation.id } })

    ['', false, 0, -1, 'invalid', '1.5'].each do |appointment_id|
      result = tool.perform(tool_context, appointment_id: appointment_id, client_comment: 'Must not be applied')

      expect(JSON.parse(result)).to eq('success' => false, 'reason' => 'validation_error', 'error_class' => 'business')
    end

    expect(appointment.reload.client_comment).to be_nil
  end

  it 'requires an appointment ID instead of selecting the latest appointment when the conversation is ambiguous' do
    resource = create(:scheduling_resource, account: account)
    conversation = create(:conversation, account: account)
    appointments = create_list(:scheduling_appointment, 2, account: account, resource: resource, conversation: conversation)
    tool_context = Struct.new(:state).new({ conversation: { id: conversation.id } })
    create(:integrations_hook, :medelement, account: account)
    resource.update!(custom_attributes: { 'medelement_specialist_code' => 'specialist-1' })

    result = nil
    expect do
      result = tool.perform(tool_context, client_comment: 'Must not be applied')
    end.not_to change(Integrations::Medelement::ProviderCommand, :count)

      expect(JSON.parse(result)).to eq('success' => false, 'reason' => 'validation_error', 'error_class' => 'business')
    expect(appointments.map { |appointment| appointment.reload.client_comment }).to all(be_nil)
  end

  it 'does not update an imported Medelement appointment' do
    resource = create(:scheduling_resource, account: account)
    contact = create(:contact, account: account)
    conversation = create(:conversation, account: account, contact: contact)
    appointment = create(
      :scheduling_appointment,
      account: account,
      resource: resource,
      contact: contact,
      conversation: conversation,
      source: 'medelement',
      external_ref: 'medelement:reception:captain-update'
    )
    tool_context = Struct.new(:state).new({ conversation: { id: conversation.id }, appointment: { id: appointment.id } })

    result = tool.perform(tool_context, client_comment: 'Changed by Captain')

    expect(JSON.parse(result)).to eq('success' => false, 'reason' => 'validation_error', 'error_class' => 'business')
    expect(appointment.reload.client_comment).to be_nil
  end

  it 'returns the exact move command receipt for a provider-backed appointment' do
    stub_provider_availability
    settings = attributes_for(:integrations_hook, :medelement)[:settings].merge('write_enabled' => true)
    create(:integrations_hook, :medelement, account: account, settings: settings)
    resource = create(:scheduling_resource, account: account, timezone: 'Asia/Almaty', custom_attributes: {
                        'medelement_specialist_code' => 'specialist-1',
                        'medelement_cabinets' => [{ 'companyCabinetCode' => 'cabinet-1' }]
                      })
    contact = create(
      :contact,
      account: account,
      name: 'Aruzhan',
      last_name: 'Testova',
      phone_number: '+77011234567',
      custom_attributes: { 'medelement_patient_code' => 'patient-1' }
    )
    conversation = create(:conversation, account: account, contact: contact)
    service = create(
      :scheduling_service,
      account: account,
      duration_min: 30,
      custom_attributes: { 'medelement_nomenclature_code' => 'service-1' }
    )
    create(:scheduling_service_price, account: account, service: service, resource: resource, active: true)
    create(:scheduling_work_rule, resource: resource, weekday: 1, start_minute: 9 * 60, end_minute: 18 * 60)
    appointment = create(
      :scheduling_appointment,
      account: account,
      resource: resource,
      contact: contact,
      conversation: conversation,
      service: service,
      external_ref: 'medelement:reception:reception-1',
      starts_at: Time.zone.parse('2026-04-20 09:00:00 +0500'),
      ends_at: Time.zone.parse('2026-04-20 09:30:00 +0500'),
      custom_attributes: { 'medelement_reception_code' => 'reception-1', 'medelement_cabinet_code' => 'cabinet-1' }
    )
    other = create_other_appointment(account: account, resource: resource, contact: contact, conversation: conversation, service: service)
    other_starts_at = other.starts_at
    tool_context = Struct.new(:state).new({ conversation: { id: conversation.id }, appointment: { id: appointment.id } })

    allow(Captain::Tools::ProviderWriteWait).to receive(:timeout_seconds).and_return(0.3)
    moved_starts_at = Time.zone.parse('2026-04-20 10:00:00 +0500').iso8601
    result = tool.perform(tool_context, appointment_id: appointment.id, starts_at: moved_starts_at)
    raise result if result.start_with?('ERROR:')

    payload = JSON.parse(result)

    # No worker answers in this example, so the tool reports that MedElement did not answer in time: a technical failure, and
    # the command nobody can wait for any more is withdrawn before it can move the reception behind the human who takes over.
    expect(payload).to include('success' => false, 'appointment_id' => appointment.id, 'status' => 'provider_confirmation_failed',
                              'provider_confirmed' => false, 'reason' => 'staff_will_help', 'error_class' => 'technical',
                              'provider_confirmation_status' => 'failed', 'provider_confirmation_operation' => 'move_reception',
                              'provider_confirmation_scope' => 'medelement')
    expect(payload.keys).to match_array(%w[success appointment_id doctor_name local_date local_time status reason provider_confirmed
                                          provider_confirmation_status provider_confirmation_operation provider_confirmation_scope
                                          move_state requested_local_date requested_local_time move_guidance error_class])
    # The appointment is still at the confirmed time; the requested time is reported only as a request.
    expect(payload).to include('local_date' => '20.04.2026', 'local_time' => '09:00', 'move_state' => 'rejected',
                               'requested_local_date' => '20.04.2026', 'requested_local_time' => '10:00')
    expect(payload['move_guidance']).to include('Do not tell the patient it was moved')
    expect(appointment.reload).to have_attributes(starts_at: Time.zone.parse('2026-04-20 09:00:00 +0500'),
                                                  ends_at: Time.zone.parse('2026-04-20 09:30:00 +0500'))
    command = Integrations::Medelement::ProviderCommand.find_by!(appointment_id: appointment.id, operation: 'move_reception')
    expect(command).to have_attributes(status: 'cancelled', last_error_code: 'agent_wait_timeout')
    expect(command.request_snapshot.dig('actor', 'type')).to eq('Captain::Assistant')
    expect(command.desired_starts_at).to eq(Time.zone.parse(moved_starts_at))
    expect(other.reload.starts_at).to eq(other_starts_at)
  end

  context 'when a provider-backed reschedule is saved' do
    let(:conversation) { create(:conversation, account: account, contact: contact) }
    let(:contact) do
      create(:contact, account: account, name: 'Aruzhan', last_name: 'Testova', phone_number: '+77011234567',
                       custom_attributes: { 'medelement_patient_code' => 'patient-1' })
    end
    let(:appointment) do
      resource = create(:scheduling_resource, account: account, timezone: 'Asia/Almaty', custom_attributes: {
                          'medelement_specialist_code' => 'specialist-1', 'medelement_cabinets' => [{ 'companyCabinetCode' => 'cabinet-1' }]
                        })
      service = create(:scheduling_service, account: account, duration_min: 30, custom_attributes: { 'medelement_nomenclature_code' => 'service-1' })
      create(:scheduling_service_price, account: account, service: service, resource: resource, active: true)
      create(:scheduling_work_rule, resource: resource, weekday: 1, start_minute: 9 * 60, end_minute: 18 * 60)
      create(:scheduling_appointment, account: account, resource: resource, contact: contact, conversation: conversation, service: service,
                                      external_ref: 'medelement:reception:reception-1',
                                      starts_at: Time.zone.parse('2026-04-20 09:00:00 +0500'), ends_at: Time.zone.parse('2026-04-20 09:30:00 +0500'),
                                      custom_attributes: { 'medelement_reception_code' => 'reception-1', 'medelement_cabinet_code' => 'cabinet-1' })
    end
    let(:tool_context) do
      Struct.new(:state).new({ conversation: { id: conversation.id }, appointment: { id: appointment.id } })
    end

    before do
      stub_provider_availability
      allow(Captain::Tools::ProviderWriteWait).to receive(:timeout_seconds).and_return(0.3)
      settings = attributes_for(:integrations_hook, :medelement)[:settings].merge('write_enabled' => true)
      create(:integrations_hook, :medelement, account: account, settings: settings)
    end

    def move!
      tool.perform(tool_context, appointment_id: appointment.id, starts_at: Time.zone.parse('2026-04-20 10:00:00 +0500').iso8601)
    end

    it 'starts the move command right away, waits for MedElement to answer it and withdraws it when no answer comes' do
      allow(Integrations::Medelement::ProviderCommandJob).to receive(:perform_later)

      result = move!
      raise result if result.start_with?('ERROR:')

      command = Integrations::Medelement::ProviderCommand.find_by!(appointment_id: appointment.id, operation: 'move_reception')
      expect(Integrations::Medelement::ProviderCommandJob).to have_received(:perform_later).with(command.id)
      expect(Captain::Tools::ProviderWriteWait).to have_received(:new).with(command: command)
      expect(command).to have_attributes(status: 'cancelled', last_error_code: 'agent_wait_timeout')
    end

    it 'records nothing about the conversation on the move command' do
      move!

      command = Integrations::Medelement::ProviderCommand.find_by!(appointment_id: appointment.id, operation: 'move_reception')
      expect(command.execution_state.keys).not_to include('ai_booking_response_fence')
    end
  end
  def create_other_appointment(account:, resource:, contact:, conversation:, service:)
    create(
      :scheduling_appointment,
      account: account,
      resource: resource,
      contact: contact,
      conversation: conversation,
      service: service,
      starts_at: Time.zone.parse('2026-04-27 09:00:00 +0500'),
      ends_at: Time.zone.parse('2026-04-27 09:30:00 +0500')
    )
  end
end
