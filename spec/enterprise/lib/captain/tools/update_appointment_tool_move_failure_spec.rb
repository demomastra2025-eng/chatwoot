require 'rails_helper'

# The agent asks for a reschedule of a MedElement reception. The tool answers only after MedElement answered the write:
# the provider's OK is a success even while a cached read still shows the old time, an explicit rejection, an ambiguous
# answer or silence is a technical failure, a taken slot is a business failure. Nothing here ever touches the conversation.
RSpec.describe Captain::Tools::UpdateAppointmentTool, type: :model do
  include ActiveSupport::Testing::TimeHelpers

  around { |example| travel_to(Time.utc(2026, 4, 19, 12)) { example.run } }

  let(:account) { create(:account, locale: 'ru').tap { |record| record.enable_features!('scheduling') } }
  let(:assistant) { create(:captain_assistant, account: account, usage_mode: 'external_agent') }
  let(:tool) { described_class.new(assistant) }
  let(:status) { Integrations::Medelement::AppointmentProviderStatus }
  let(:original_starts_at) { Time.zone.parse('2026-04-20 09:00:00 +0500') }
  let(:original_ends_at) { Time.zone.parse('2026-04-20 09:30:00 +0500') }
  let(:requested_starts_at) { Time.zone.parse('2026-04-20 10:00:00 +0500') }
  let(:requested_ends_at) { Time.zone.parse('2026-04-20 10:30:00 +0500') }
  let(:contact) do
    create(:contact, account: account, name: 'Aruzhan', last_name: 'Testova', phone_number: '+77011234567',
                     custom_attributes: { 'medelement_patient_code' => 'patient-1' })
  end
  let(:conversation) { create(:conversation, account: account, contact: contact, status: :pending) }
  let(:resource) do
    create(:scheduling_resource, account: account, timezone: 'Asia/Almaty', custom_attributes: {
             'medelement_specialist_code' => 'specialist-1', 'medelement_cabinets' => [{ 'companyCabinetCode' => 'cabinet-1' }]
           })
  end
  let!(:appointment) do
    create(:scheduling_work_rule, resource: resource, weekday: 1, start_minute: 9 * 60, end_minute: 18 * 60)
    create(:scheduling_appointment, account: account, resource: resource, contact: contact, conversation: conversation, service: nil,
                                    external_ref: 'medelement:reception:reception-1', starts_at: original_starts_at, ends_at: original_ends_at,
                                    custom_attributes: { 'medelement_reception_code' => 'reception-1', 'medelement_cabinet_code' => 'cabinet-1',
                                                         status::ATTRIBUTE_KEY => status::SUCCEEDED })
  end
  let(:client) { instance_double(Integrations::Medelement::Client) }
  let(:tool_context) do
    Struct.new(:state).new({ conversation: { id: conversation.id }, appointment: { id: appointment.id } })
  end
  let(:execute_commands_inline) { true }

  before do
    create(:captain_inbox, inbox: conversation.inbox, captain_assistant: assistant)
    create(:integrations_hook, :medelement, account: account,
                                            settings: attributes_for(:integrations_hook, :medelement)[:settings].merge('write_enabled' => true))
    availability = Integrations::Medelement::ResourceAvailabilityService::Result.new(
      status: 'fresh', checked_at: Time.current, slots: [{}], reason: nil
    )
    allow(Integrations::Medelement::ResourceAvailabilityService).to receive(:new)
      .and_return(instance_double(Integrations::Medelement::ResourceAvailabilityService, perform: availability))
    allow(Integrations::Medelement::CronScheduleService).to receive(:new)
      .and_return(instance_double(Integrations::Medelement::CronScheduleService, sync!: true))
    allow(Integrations::Medelement::Client).to receive(:new).and_return(client)
    stub_provider_reads
    allow(Captain::Tools::ProviderWriteWait).to receive(:timeout_seconds).and_return(0.4)
    # The queue worker: the command that was just dispatched runs right away, like on a free worker.
    allow(Integrations::Medelement::ProviderCommandJob).to receive(:perform_later) do |command_id|
      next unless execute_commands_inline

      Integrations::Medelement::ProviderCommands::Executor.new(command: Integrations::Medelement::ProviderCommand.find(command_id)).perform
    end
  end

  def provider_time(value)
    value.in_time_zone('Asia/Almaty').strftime('%d.%m.%Y %H:%M:%S')
  end

  def reception_readback(starts_at, ends_at, cabinet: true)
    {
      'RECEPTION_CODE' => 'reception-1', 'PROFILE_CODE' => 'patient-1', 'SPECIALIST_CODE' => 'specialist-1',
      'STARTTIME' => provider_time(starts_at), 'ENDTIME' => provider_time(ends_at), 'REMOVED' => 0
    }.merge(cabinet ? { 'COMPANY_CABINET_CODE' => 'cabinet-1' } : {})
  end

  # A cached read server keeps showing the old time: nothing but the preflight ever reads the reception.
  def stub_provider_reads(occupied: [])
    allow(client).to receive(:get_patient).with(patient_code: 'patient-1').and_return(
      'PROFILE_CODE' => 'patient-1', 'PATIENT_PHONE_2' => contact.phone_number
    )
    allow(client).to receive(:get_reception).and_return(reception_readback(original_starts_at, original_ends_at, cabinet: false))
    allow(client).to receive(:timetable).and_return(
      requested_starts_at.in_time_zone('Asia/Almaty').strftime('%d.%m.%Y') => {
        'timetable' => [{ 'start' => provider_time(requested_starts_at), 'end' => provider_time(requested_ends_at), 'working' => true }]
      }
    )
    allow(client).to receive(:get_receptions).and_return(
      [{ 'RECEPTION_CODE' => 'reception-1', 'COMPANY_CABINET_CODE' => 'cabinet-1' }], occupied
    )
  end

  def request_move
    JSON.parse(tool.perform(tool_context, appointment_id: appointment.id, starts_at: requested_starts_at.iso8601))
  end

  def move_command
    Integrations::Medelement::ProviderCommand.find_by!(appointment_id: appointment.id, operation: 'move_reception')
  end

  def expect_conversation_untouched
    expect(conversation.messages.outgoing).to be_empty
    expect(conversation.reload.status).to eq('pending')
    expect(conversation.current_captain_control_state).not_to eq('human')
  end

  it 'reports a successful move as soon as MedElement answers OK, although its read still shows the old time' do
    allow(client).to receive(:move_reception).and_return({})

    payload = request_move

    expect(payload).to include(
      'success' => true, 'status' => 'updated', 'provider_confirmed' => true, 'local_date' => '20.04.2026', 'local_time' => '10:00'
    )
    expect(payload).not_to include('error_class', 'move_state')
    expect(move_command).to be_succeeded
    expect(appointment.reload).to have_attributes(starts_at: requested_starts_at, ends_at: requested_ends_at)
    expect(appointment.custom_attributes).not_to have_key('medelement_move_request')
    expect(client).to have_received(:move_reception).once
    expect(client).to have_received(:get_reception).once
    expect_conversation_untouched
  end

  it 'reports an explicit MedElement rejection as a technical failure and keeps the confirmed time' do
    allow(client).to receive(:move_reception).and_raise(Integrations::Medelement::Client::ApiError.new('rejected', status: 400))

    payload = request_move

    expect(payload).to include(
      'success' => false, 'status' => 'provider_confirmation_failed', 'provider_confirmed' => false, 'error_class' => 'technical',
      'move_state' => 'rejected', 'local_date' => '20.04.2026', 'local_time' => '09:00', 'requested_local_time' => '10:00'
    )
    expect(move_command).to be_failed
    expect(appointment.reload).to have_attributes(starts_at: original_starts_at, ends_at: original_ends_at, status: 'scheduled')
    expect(appointment.custom_attributes['medelement_move_request']).to include('state' => 'rejected', 'evidence' => 'provider_rejected')
    expect(client).to have_received(:move_reception).once
    expect_conversation_untouched
  end

  it 'reports an ambiguous MedElement answer as a technical failure that is still unconfirmed' do
    allow(client).to receive(:move_reception).and_raise(
      Integrations::Medelement::Client::ApiError.new('Medelement reception move request failed', status: 503, ambiguous: true)
    )

    payload = request_move

    expect(payload).to include('success' => false, 'provider_confirmed' => false, 'error_class' => 'technical',
                               'move_state' => 'needs_reconciliation', 'local_time' => '09:00')
    expect(move_command).to be_reconciliation_required
    expect(appointment.reload).to have_attributes(starts_at: original_starts_at)
    expect_conversation_untouched
  end

  context 'when MedElement does not answer in time' do
    let(:execute_commands_inline) { false }

    it 'reports a technical failure, and the late OK only updates the calendar' do
      allow(client).to receive(:move_reception).and_return({})

      payload = request_move

      expect(payload).to include('success' => false, 'status' => 'pending_provider_confirmation', 'provider_confirmed' => false,
                                 'error_class' => 'technical', 'move_state' => 'pending', 'local_time' => '09:00')
      expect(appointment.reload).to have_attributes(starts_at: original_starts_at)
      expect_conversation_untouched

      Integrations::Medelement::ProviderCommands::Executor.new(command: move_command).perform

      expect(move_command).to be_succeeded
      expect(appointment.reload).to have_attributes(starts_at: requested_starts_at, ends_at: requested_ends_at)
      expect_conversation_untouched
    end
  end

  context 'when the requested time is already taken in MedElement' do
    before { stub_provider_reads(occupied: [{ 'RECEPTION_CODE' => 'other-1', 'STARTTIME' => provider_time(requested_starts_at), 'ENDTIME' => provider_time(requested_ends_at), 'REMOVED' => 0 }]) }

    it 'reports a business failure the agent can act on' do
      allow(client).to receive(:move_reception)

      payload = request_move

      expect(payload).to eq('success' => false, 'reason' => 'time_taken', 'error_class' => 'business')
      expect(move_command).to have_attributes(status: 'failed', last_error_code: 'slot_conflict')
      expect(appointment.reload).to have_attributes(starts_at: original_starts_at)
      expect(client).not_to have_received(:move_reception)
      expect_conversation_untouched
    end
  end

  it 'cannot change the specialist of a linked reception and leaves the appointment and the provider untouched' do
    allow(client).to receive(:move_reception)
    replacement = create(:scheduling_resource, account: account, timezone: 'Asia/Almaty', custom_attributes: {
                           'medelement_specialist_code' => 'specialist-2', 'medelement_cabinets' => [{ 'companyCabinetCode' => 'cabinet-1' }]
                         })

    payload = JSON.parse(tool.perform(tool_context, appointment_id: appointment.id, resource_id: replacement.id,
                                                    starts_at: requested_starts_at.iso8601))

    expect(payload).to include('success' => false, 'reason' => 'staff_will_help', 'error_class' => 'technical')
    expect(appointment.reload).to have_attributes(resource_id: resource.id, starts_at: original_starts_at, ends_at: original_ends_at)
    expect(appointment.custom_attributes).not_to have_key('medelement_move_request')
    expect(Integrations::Medelement::ProviderCommand.where(appointment_id: appointment.id, operation: 'move_reception')).to be_empty
    expect(client).not_to have_received(:move_reception)
  end

  it 'does not wait for MedElement when the change starts no provider command' do
    allow(client).to receive(:move_reception)
    appointment.update!(custom_attributes: appointment.custom_attributes.merge('medelement_provider_operation' => 'create_reception'))

    payload = JSON.parse(tool.perform(tool_context, appointment_id: appointment.id, client_comment: 'Please call before the visit'))

    expect(payload).to include('success' => true, 'status' => 'updated')
    expect(Integrations::Medelement::ProviderCommand.where(appointment_id: appointment.id)).to be_empty
    expect(client).not_to have_received(:move_reception)
  end
end
