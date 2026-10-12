require 'rails_helper'

# DEV-001 end to end: the agent asks for a reschedule and MedElement rejects the write with HTTP 400. The appointment must
# keep its confirmed time, the agent must never report the move as done, and the customer must hear once that the
# change could not be confirmed.
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
  let(:incoming) { create(:message, conversation: conversation, message_type: :incoming) }
  let(:fence) do
    { control_generation: conversation.current_captain_control_generation,
      status_transition_id: conversation.status_transitions.maximum(:id).to_i, last_message_id: incoming.id }
  end
  let(:tool_context) do
    Struct.new(:state).new({ conversation: { id: conversation.id }, appointment: { id: appointment.id }, captain_response_fence: fence })
  end
  let(:rejection) { Integrations::Medelement::Client::ApiError.new('Medelement reception move request failed', status: 400) }
  let(:notice) { 'Не получилось подтвердить перенос записи. Администратор проверит и свяжется с вами.' }

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
    allow(client).to receive(:move_reception).and_raise(rejection)
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

  def stub_provider_reads
    allow(client).to receive(:get_patient).with(patient_code: 'patient-1').and_return(
      'PROFILE_CODE' => 'patient-1', 'PATIENT_PHONE_2' => contact.phone_number
    )
    allow(client).to receive(:get_reception).and_return(reception_readback(original_starts_at, original_ends_at, cabinet: false))
    allow(client).to receive(:timetable).and_return(
      requested_starts_at.in_time_zone('Asia/Almaty').strftime('%d.%m.%Y') => {
        'timetable' => [{ 'start' => provider_time(requested_starts_at), 'end' => provider_time(requested_ends_at), 'working' => true }]
      }
    )
    allow(client).to receive(:get_receptions).and_return([{ 'RECEPTION_CODE' => 'reception-1', 'COMPANY_CABINET_CODE' => 'cabinet-1' }], [])
  end

  def request_move!
    JSON.parse(tool.perform(tool_context, appointment_id: appointment.id, starts_at: requested_starts_at.iso8601)).tap do |payload|
      raise payload.to_s if payload['reason'].in?(%w[validation_error staff_will_help not_found])
    end
  end

  def move_command
    Integrations::Medelement::ProviderCommand.find_by!(appointment_id: appointment.id, operation: 'move_reception')
  end

  def execute_move!
    command = move_command
    Integrations::Medelement::ProviderCommandConfirmationJob.perform_now(command.confirmation_request_id)
    Integrations::Medelement::ProviderCommands::Executor.new(command: command.reload).perform
    command.reload
  end

  def public_messages
    conversation.messages.outgoing.where(private: false)
  end

  it 'tells the agent the move is only requested while MedElement has not answered' do
    payload = request_move!

    expect(payload).to include(
      'success' => false, 'status' => 'pending_provider_confirmation', 'provider_confirmed' => false, 'move_state' => 'pending',
      'local_date' => '20.04.2026', 'local_time' => '09:00', 'requested_local_date' => '20.04.2026', 'requested_local_time' => '10:00'
    )
    expect(appointment.reload).to have_attributes(starts_at: original_starts_at, ends_at: original_ends_at)
    expect(public_messages).to be_empty
  end

  it 'cannot change the specialist of a linked reception and leaves the appointment and the provider untouched' do
    replacement = create(:scheduling_resource, account: account, timezone: 'Asia/Almaty', custom_attributes: {
                           'medelement_specialist_code' => 'specialist-2', 'medelement_cabinets' => [{ 'companyCabinetCode' => 'cabinet-1' }]
                         })

    payload = JSON.parse(tool.perform(tool_context, appointment_id: appointment.id, resource_id: replacement.id,
                                                    starts_at: requested_starts_at.iso8601))

    expect(payload).to include('success' => false, 'reason' => 'staff_will_help')
    expect(appointment.reload).to have_attributes(resource_id: resource.id, starts_at: original_starts_at, ends_at: original_ends_at)
    expect(appointment.custom_attributes).not_to have_key('medelement_move_request')
    expect(Integrations::Medelement::ProviderCommand.where(appointment_id: appointment.id, operation: 'move_reception')).to be_empty
    expect(client).not_to have_received(:move_reception)
  end

end
