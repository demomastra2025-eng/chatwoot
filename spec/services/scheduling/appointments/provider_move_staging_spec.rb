require 'rails_helper'

# A reschedule of a MedElement-linked appointment is a request until the provider confirms it: the appointment keeps the
# interval MedElement confirmed, the requested interval and the command outcome are recorded, and a rejected or unknown
# result never shows the requested time as confirmed. DEV-001: command 160 was rejected with HTTP 400 while OneLink kept
# the new time as an ordinary scheduled appointment.
RSpec.describe 'MedElement-linked reschedule' do
  include ActiveSupport::Testing::TimeHelpers

  around { |example| travel_to(Time.utc(2026, 4, 19, 12)) { example.run } }

  let(:account) { create(:account).tap { |record| record.enable_features!('scheduling') } }
  let(:user) { create(:user, account: account) }
  let(:status) { Integrations::Medelement::AppointmentProviderStatus }
  let(:move_state) { Integrations::Medelement::AppointmentMoveState }
  let(:original_starts_at) { Time.zone.parse('2026-04-20 09:00:00 +0500') }
  let(:original_ends_at) { Time.zone.parse('2026-04-20 09:30:00 +0500') }
  let(:requested_starts_at) { Time.zone.parse('2026-04-20 10:00:00 +0500') }
  let(:requested_ends_at) { Time.zone.parse('2026-04-20 10:30:00 +0500') }
  let(:resource) do
    create(:scheduling_resource, account: account, timezone: 'Asia/Almaty', custom_attributes: {
             'medelement_specialist_code' => 'specialist-1', 'medelement_cabinets' => [{ 'companyCabinetCode' => 'cabinet-1' }]
           })
  end
  let(:contact) do
    create(:contact, account: account, name: 'Aruzhan', last_name: 'Testova', phone_number: '+77011234567',
                     custom_attributes: { 'medelement_patient_code' => 'patient-1' })
  end
  let(:client) { instance_double(Integrations::Medelement::Client) }
  let!(:appointment) do
    create(:scheduling_work_rule, resource: resource, weekday: 1, start_minute: 9 * 60, end_minute: 18 * 60)
    create(
      :scheduling_appointment,
      account: account, resource: resource, contact: contact, service: nil, source: 'manual',
      external_ref: 'medelement:reception:reception-1', starts_at: original_starts_at, ends_at: original_ends_at,
      custom_attributes: {
        'medelement_reception_code' => 'reception-1', 'medelement_cabinet_code' => 'cabinet-1', status::ATTRIBUTE_KEY => status::SUCCEEDED
      }
    )
  end

  before do
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
  end

  def perform(params)
    Scheduling::Appointments::UpsertService.new(
      account: account, appointment: Scheduling::Appointment.find(appointment.id), params: params, actor: user
    ).perform
  end

  def move_commands
    Integrations::Medelement::ProviderCommand.where(appointment: appointment, operation: 'move_reception')
  end

  def move_entry
    appointment.reload.custom_attributes[move_state::ATTRIBUTE_KEY]
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

  def stub_preflight
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

  def execute_move!
    command = move_commands.sole
    Integrations::Medelement::ProviderCommandConfirmationJob.perform_now(command.confirmation_request_id)
    Integrations::Medelement::ProviderCommands::Executor.new(command: command.reload).perform
    command.reload
  end

  def reconcile!(command)
    Integrations::Medelement::ProviderCommands::ReconciliationService.new(command: command.reload).perform
    command.reload
  end

  it 'keeps the confirmed interval and queues one move command for the requested interval' do
    result = perform(starts_at: requested_starts_at.iso8601)

    expect(result.reload).to have_attributes(starts_at: original_starts_at, ends_at: original_ends_at, duration_min: 30, status: 'scheduled')
    command = move_commands.sole
    expect(command).to have_attributes(desired_starts_at: requested_starts_at, desired_ends_at: requested_ends_at)
    expect(command.request_snapshot['reception']).to include(
      'source_starts_at' => original_starts_at.utc.iso8601(6), 'source_ends_at' => original_ends_at.utc.iso8601(6),
      'destination_starts_at' => requested_starts_at.utc.iso8601(6), 'destination_ends_at' => requested_ends_at.utc.iso8601(6)
    )
    expect(result.medelement_provider_command_receipt).to eq(command)
    expect(result.custom_attributes).to include(status::ATTRIBUTE_KEY => status::PENDING, status::COMMAND_ID_KEY => command.id)
    expect(move_entry).to include(
      'state' => 'pending', 'command_id' => command.id,
      'confirmed_starts_at' => original_starts_at.utc.iso8601(6), 'requested_starts_at' => requested_starts_at.utc.iso8601(6),
      'requested_ends_at' => requested_ends_at.utc.iso8601(6)
    )
    expect(Scheduling::PayloadBuilder.appointment(result)).to include(
      starts_at: original_starts_at.iso8601, provider_confirmed: false,
      provider_move: hash_including(state: 'pending', requested_time_confirmed: false, requested_starts_at: requested_starts_at.utc.iso8601(6))
    )
  end

  it 'applies the requested interval as soon as the provider answers OK, although a cached read still shows the old time' do
    perform(starts_at: requested_starts_at.iso8601)
    stub_preflight
    allow(client).to receive(:move_reception).and_return({})
    allow(Reminders::SyncRemindableService).to receive(:new).and_call_original

    command = execute_move!

    expect(Reminders::SyncRemindableService).to have_received(:new).with(remindable: an_instance_of(Scheduling::Appointment))
    expect(command).to be_succeeded
    expect(appointment.reload).to have_attributes(starts_at: requested_starts_at, ends_at: requested_ends_at, duration_min: 30)
    expect(appointment.custom_attributes).to include(status::ATTRIBUTE_KEY => status::SUCCEEDED)
    expect(appointment.custom_attributes).not_to have_key(move_state::ATTRIBUTE_KEY)
    expect(client).to have_received(:move_reception).once
    # Nothing but the preflight read the reception: the OK is final and no read-back is awaited.
    expect(client).to have_received(:get_reception).once
  end

  it 'repeats the same request without a second command and refuses a different one while the first is unfinished' do
    first = perform(starts_at: requested_starts_at.iso8601).medelement_provider_command_receipt
    repeated = perform(starts_at: requested_starts_at.iso8601).medelement_provider_command_receipt

    expect(repeated).to eq(first)
    expect(move_commands.count).to eq(1)

    expect { perform(starts_at: (requested_starts_at + 1.hour).iso8601) }.to raise_error(Scheduling::Error) do |error|
      expect(error.code).to eq('MEDELEMENT_COMMAND_IN_PROGRESS')
    end
    expect(appointment.reload).to have_attributes(starts_at: original_starts_at, ends_at: original_ends_at)
    expect(move_entry).to include('requested_starts_at' => requested_starts_at.utc.iso8601(6))
    expect(move_commands.count).to eq(1)
  end

  it 'does not stage an edit that leaves the interval alone' do
    perform(client_comment: 'Bring the previous results')

    expect(appointment.reload).to have_attributes(client_comment: 'Bring the previous results', starts_at: original_starts_at)
    expect(appointment.custom_attributes).not_to have_key(move_state::ATTRIBUTE_KEY)
    expect(move_commands).to be_empty
  end

  context 'when MedElement rejects the move with HTTP 400' do
    let(:rejection) do
      Integrations::Medelement::Client::ApiError.new('Medelement reception move request failed', status: 400, provider_message: 'Bad time')
    end

    before do
      perform(starts_at: requested_starts_at.iso8601)
      stub_preflight
      allow(client).to receive(:move_reception).and_raise(rejection)
    end

    it 'fails the command at once, keeps the original time and shows the rejection, without any read-back' do
      expect { execute_move! }.not_to have_enqueued_job(Integrations::Medelement::ProviderCommandReconciliationJob)
      command = move_commands.sole

      expect(command).to be_failed
      expect(command).to have_attributes(last_error_code: 'provider_http_error', last_error_status: 400)
      expect(command.execution_state['write_failure']).to include('code' => 'provider_http_error', 'status' => 400, 'provider_message' => 'Bad time')
      expect(appointment.reload).to have_attributes(starts_at: original_starts_at, ends_at: original_ends_at, status: 'scheduled')
      # The rejection leaves the reception where it was: the appointment stays provider-confirmed, only the move request is rejected.
      expect(appointment.custom_attributes).to include(status::ATTRIBUTE_KEY => status::SUCCEEDED, status::COMMAND_ID_KEY => command.id)
      expect(move_entry).to include(
        'state' => 'rejected', 'evidence' => 'provider_rejected', 'error_code' => 'provider_http_error', 'error_status' => 400,
        'confirmed_starts_at' => original_starts_at.utc.iso8601(6), 'requested_starts_at' => requested_starts_at.utc.iso8601(6)
      )
      expect(client).to have_received(:get_reception).once

      Integrations::Medelement::ProviderCommands::Executor.new(command: command).perform
      expect(client).to have_received(:move_reception).once
    end

    it 'tells the agent the move is not applied and reports the confirmed time as the appointment time' do
      execute_move!

      result = Captain::Tools::Agent::AppointmentResult.success(appointment.reload, action: 'update_appointment')

      expect(result).to include(
        success: false, provider_confirmed: false, status: 'provider_confirmation_failed', move_state: 'rejected',
        local_date: '20.04.2026', local_time: '09:00', requested_local_date: '20.04.2026', requested_local_time: '10:00'
      )
      expect(result[:move_guidance]).to include('did not apply the reschedule')
    end

    context 'after the rejection' do
      before do
        Integrations::Medelement::ProviderCommand.create!(
          account: account, appointment: appointment, contact: contact, operation: 'create_reception', status: 'succeeded',
          idempotency_key: 'original-create', company_cabinet_code: 'cabinet-1',
          desired_starts_at: original_starts_at, desired_ends_at: original_ends_at
        )
        execute_move!
      end

      def import!(starts_at, ends_at)
        Integrations::Medelement::AppointmentImporterService.new(account: account).upsert!(
          resource: resource, contact: contact,
          reception: { 'RECEPTION_CODE' => 'reception-1', 'PATIENT_CODE' => 'patient-1', 'ACTIVE' => 1 },
          import_context: { starts_at: starts_at, ends_at: ends_at, specialist_code: 'specialist-1' }
        )
      end

      it 'presents the reception as provider-confirmed at its previous time with the rejected request attached' do
        expect(Scheduling::PayloadBuilder.appointment(appointment.reload)).to include(
          starts_at: original_starts_at.iso8601, provider_confirmed: true,
          provider_move: hash_including(state: 'rejected', requested_time_confirmed: false)
        )
      end

      it 'still lets the reception sync import the reception and keeps the rejection while the provider shows the same interval' do
        imported = import!(original_starts_at, original_ends_at)

        expect(imported.reload).to have_attributes(id: appointment.id, source: 'manual', starts_at: original_starts_at, ends_at: original_ends_at)
        expect(imported.custom_attributes).to include(status::ATTRIBUTE_KEY => status::SUCCEEDED, 'source_mode' => 'outbound')
        expect(move_entry).to include('state' => 'rejected', 'evidence' => 'provider_rejected')
      end

      it 'follows the provider when it shows another interval and drops the rejection that is no longer true' do
        imported = import!(original_starts_at + 2.hours, original_ends_at + 2.hours)

        expect(imported.reload).to have_attributes(starts_at: original_starts_at + 2.hours, ends_at: original_ends_at + 2.hours)
        expect(imported.custom_attributes).not_to have_key(move_state::ATTRIBUTE_KEY)
      end
    end

    it 'treats a new request after the rejection as a new explicit move, not as a retry of the failed command' do
      rejected_command = execute_move!
      expect(rejected_command).to be_failed

      travel 1.minute
      perform(starts_at: requested_starts_at.iso8601)

      expect(move_commands.count).to eq(2)
      expect(move_commands.order(:id).last).not_to eq(rejected_command)
      expect(appointment.reload.custom_attributes).to include(status::ATTRIBUTE_KEY => status::PENDING)
      expect(move_entry).to include('state' => 'pending')
      expect(move_entry).not_to have_key('evidence')
    end
  end

  context 'when the result of the move write is ambiguous' do
    before do
      perform(starts_at: requested_starts_at.iso8601)
      stub_preflight
      allow(client).to receive(:move_reception).and_raise(
        Integrations::Medelement::Client::ApiError.new('Medelement reception move request failed', status: 503, ambiguous: true)
      )
    end

    it 'keeps the original time confirmed and flags the request for reconciliation, never repeating the write' do
      command = execute_move!

      expect(command).to be_reconciliation_required
      expect(command).to have_attributes(last_error_code: 'provider_http_error', last_error_status: 503)
      expect(appointment.reload).to have_attributes(starts_at: original_starts_at, ends_at: original_ends_at, status: 'scheduled')
      expect(appointment.custom_attributes).to include(status::ATTRIBUTE_KEY => status::UNKNOWN)
      expect(move_entry).to include(
        'state' => 'needs_reconciliation', 'error_code' => 'provider_http_error', 'error_status' => 503,
        'confirmed_starts_at' => original_starts_at.utc.iso8601(6), 'requested_starts_at' => requested_starts_at.utc.iso8601(6)
      )

      Integrations::Medelement::ProviderCommands::Executor.new(command: command).perform
      expect(client).to have_received(:move_reception).once
    end

    it 'tells the agent the move is not applied and not established' do
      execute_move!

      result = Captain::Tools::Agent::AppointmentResult.success(appointment.reload, action: 'update_appointment')

      expect(result).to include(
        success: false, provider_confirmed: false, status: 'provider_status_unknown', move_state: 'needs_reconciliation',
        local_date: '20.04.2026', local_time: '09:00', requested_local_time: '10:00'
      )
      expect(result[:move_guidance]).to include('Do not tell the patient it was moved')
    end

    it 'does not close the move on a read that still shows the old time, because a cached server shows it for a while' do
      command = execute_move!
      allow(client).to receive(:get_reception).and_return(reception_readback(original_starts_at, original_ends_at))

      command = reconcile!(command)

      expect(command).to be_reconciliation_required
      expect(appointment.reload).to have_attributes(starts_at: original_starts_at)
      expect(appointment.custom_attributes).to include(status::ATTRIBUTE_KEY => status::UNKNOWN)
      expect(move_entry).to include('state' => 'needs_reconciliation')
      expect(client).to have_received(:move_reception).once
    end

    it 'applies the provider time when a read shows the move happened anyway' do
      command = execute_move!
      allow(client).to receive(:get_reception).and_return(reception_readback(requested_starts_at, requested_ends_at))

      command = reconcile!(command)

      expect(command).to be_succeeded
      expect(appointment.reload).to have_attributes(starts_at: requested_starts_at, ends_at: requested_ends_at)
      expect(appointment.custom_attributes).to include(status::ATTRIBUTE_KEY => status::SUCCEEDED)
      expect(appointment.custom_attributes).not_to have_key(move_state::ATTRIBUTE_KEY)
      expect(client).to have_received(:move_reception).once
    end

    it 'keeps the request flagged when the provider cannot be read' do
      command = execute_move!
      command.update!(execution_state: command.execution_state.merge('reconciliation_attempts' => 5))
      allow(client).to receive(:get_reception).and_raise(Integrations::Medelement::Client::ApiError.new('unavailable', status: 503))

      command = reconcile!(command)

      expect(command).to be_provider_status_unknown
      expect(appointment.reload).to have_attributes(starts_at: original_starts_at, ends_at: original_ends_at)
      expect(appointment.custom_attributes).to include(status::ATTRIBUTE_KEY => status::UNKNOWN)
      expect(move_entry).to include('state' => 'needs_reconciliation', 'requested_starts_at' => requested_starts_at.utc.iso8601(6))
      expect(client).to have_received(:move_reception).once
    end

    it 'does not treat a read at an unrelated time as evidence either way' do
      command = execute_move!
      allow(client).to receive(:get_reception).and_return(reception_readback(original_starts_at + 3.hours, original_ends_at + 3.hours))

      command = reconcile!(command)

      expect(command).to be_reconciliation_required
      expect(appointment.reload).to have_attributes(starts_at: original_starts_at)
      expect(move_entry).to include('state' => 'needs_reconciliation')
    end
  end

  context 'when the move fails before anything is sent' do
    it 'marks the request rejected without a read-back and leaves the confirmed interval' do
      perform(starts_at: requested_starts_at.iso8601)
      stub_preflight
      allow(client).to receive(:get_receptions).and_return(
        [{ 'RECEPTION_CODE' => 'reception-1', 'COMPANY_CABINET_CODE' => 'cabinet-1' }],
        [{ 'RECEPTION_CODE' => 'other', 'STARTTIME' => provider_time(requested_starts_at), 'ENDTIME' => provider_time(requested_ends_at),
           'REMOVED' => 0 }]
      )
      allow(client).to receive(:move_reception)

      command = execute_move!

      expect(command).to be_failed
      expect(command.last_error_code).to eq('slot_conflict')
      expect(client).not_to have_received(:move_reception)
      expect(appointment.reload).to have_attributes(starts_at: original_starts_at, ends_at: original_ends_at)
      expect(appointment.custom_attributes).to include(status::ATTRIBUTE_KEY => status::SUCCEEDED)
      expect(move_entry).to include('state' => 'rejected', 'evidence' => 'not_sent', 'error_code' => 'slot_conflict')
    end
  end

  # MedElement moves a reception in time only. A specialist or cabinet change could never pass the provider preflight, so it
  # is refused instead of reaching the row as an appointment nobody confirmed (the first symptom of DEV-001).
  context 'when the change would replace the specialist or the cabinet of the linked reception' do
    let!(:replacement) do
      create(:scheduling_resource, account: account, timezone: 'Asia/Almaty', custom_attributes: {
               'medelement_specialist_code' => 'specialist-2',
               'medelement_cabinets' => [{ 'companyCabinetCode' => 'cabinet-1' }, { 'companyCabinetCode' => 'cabinet-2' }]
             }).tap { |record| create(:scheduling_work_rule, resource: record, weekday: 1, start_minute: 9 * 60, end_minute: 18 * 60) }
    end

    def expect_refused_untouched(params)
      expect { perform(params) }.to raise_error(Scheduling::Error) do |error|
        expect(error).to have_attributes(code: 'MEDELEMENT_RESOURCE_CHANGE_UNSUPPORTED', status: 422)
      end
      expect(appointment.reload).to have_attributes(resource_id: resource.id, starts_at: original_starts_at, ends_at: original_ends_at)
      expect(appointment.custom_attributes).to include(status::ATTRIBUTE_KEY => status::SUCCEEDED, 'medelement_cabinet_code' => 'cabinet-1')
      expect(appointment.custom_attributes).not_to have_key(move_state::ATTRIBUTE_KEY)
      expect(move_commands).to be_empty
    end

    it 'refuses a specialist change together with a new time' do
      expect_refused_untouched(resource_id: replacement.id, starts_at: requested_starts_at.iso8601)
    end

    it 'refuses a specialist change alone, which would otherwise queue a move nobody can confirm' do
      expect_refused_untouched(resource_id: replacement.id)
    end

    it 'refuses a different cabinet together with a new time' do
      resource.update!(custom_attributes: resource.custom_attributes.merge(
        'medelement_cabinets' => [{ 'companyCabinetCode' => 'cabinet-1' }, { 'companyCabinetCode' => 'cabinet-2' }]
      ))

      expect_refused_untouched(starts_at: requested_starts_at.iso8601, custom_attributes: { 'medelement_cabinet_code' => 'cabinet-2' })
    end

    it 'still stages a plain time change that repeats the recorded specialist and cabinet' do
      perform(resource_id: resource.id, starts_at: requested_starts_at.iso8601, custom_attributes: { 'medelement_cabinet_code' => 'cabinet-1' })

      expect(appointment.reload).to have_attributes(resource_id: resource.id, starts_at: original_starts_at)
      expect(move_entry).to include('state' => 'pending')
      expect(move_commands.count).to eq(1)
    end
  end
end
