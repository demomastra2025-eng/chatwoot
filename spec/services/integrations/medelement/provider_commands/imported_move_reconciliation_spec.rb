require 'rails_helper'

# A move requested for a provider-owned (imported) appointment freezes the appointment it was confirmed against. While the
# result of the write is unresolved the appointment must stay as it was, or the reconciliation refuses the result as stale
# and the command can never finish (the unfinished command then blocks every later change of that reception).
RSpec.describe 'Move of an imported MedElement appointment' do
  include ActiveSupport::Testing::TimeHelpers

  around { |example| travel_to(Time.utc(2026, 4, 19, 12)) { example.run } }

  let(:account) { create(:account, locale: 'ru').tap { |record| record.enable_features!('scheduling') } }
  let(:user) { create(:user, account: account) }
  let(:original_starts_at) { Time.zone.parse('2026-04-20 09:00:00 +0500') }
  let(:original_ends_at) { Time.zone.parse('2026-04-20 09:30:00 +0500') }
  let(:requested_starts_at) { Time.zone.parse('2026-04-20 10:00:00 +0500') }
  let(:requested_ends_at) { Time.zone.parse('2026-04-20 10:30:00 +0500') }
  let(:contact) do
    create(:contact, account: account, name: 'Aruzhan', last_name: 'Testova', phone_number: '+77011234567',
                     custom_attributes: { 'medelement_patient_code' => 'patient-1' })
  end
  let(:resource) do
    create(:scheduling_resource, account: account, timezone: 'Asia/Almaty', custom_attributes: {
             'medelement_specialist_code' => 'specialist-1', 'medelement_cabinets' => [{ 'companyCabinetCode' => 'cabinet-1' }]
           })
  end
  let!(:appointment) do
    create(:scheduling_work_rule, resource: resource, weekday: 1, start_minute: 9 * 60, end_minute: 18 * 60)
    create(:scheduling_appointment, account: account, resource: resource, contact: contact, service: nil, source: 'medelement',
                                    external_ref: 'medelement:reception:reception-1', starts_at: original_starts_at, ends_at: original_ends_at,
                                    custom_attributes: { 'medelement_reception_code' => 'reception-1', 'medelement_cabinet_code' => 'cabinet-1' })
  end
  let(:client) { instance_double(Integrations::Medelement::Client) }

  before do
    create(:integrations_hook, :medelement, account: account,
                                            settings: attributes_for(:integrations_hook, :medelement)[:settings].merge('write_enabled' => true))
    availability = Integrations::Medelement::ResourceAvailabilityService::Result.new(
      status: 'fresh', checked_at: Time.current, slots: [{}], reason: nil
    )
    allow(Integrations::Medelement::ResourceAvailabilityService).to receive(:new) do |**options|
      options[:candidate_slots]&.call([[requested_starts_at, requested_ends_at]])
      instance_double(Integrations::Medelement::ResourceAvailabilityService, perform: availability)
    end
    allow(Integrations::Medelement::Client).to receive(:new).and_return(client)
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
    Scheduling::Appointments::ImportedProviderMutationService.new(
      appointment: Scheduling::Appointment.find(appointment.id), actor: user, operation: 'move_reception',
      params: { starts_at: requested_starts_at.iso8601 }, appointment_access: nil
    ).perform
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

  def move_command
    Integrations::Medelement::ProviderCommand.where(appointment: appointment, operation: 'move_reception').sole
  end

  def execute_move!
    command = move_command
    Integrations::Medelement::ProviderCommandConfirmationJob.perform_now(command.confirmation_request_id)
    Integrations::Medelement::ProviderCommands::Executor.new(command: command.reload).perform
    command.reload
  end

  def reconcile!(command)
    Integrations::Medelement::ProviderCommands::ReconciliationService.new(command: command.reload).perform
    command.reload
  end

  def unresolved_command!
    command = execute_move!
    expect(command).to be_reconciliation_required
    expect(command.frozen_imported_source?).to be(true)
    # The imported appointment is not touched while the result is unresolved.
    expect(appointment.reload.custom_attributes).not_to include('medelement_provider_sync_status', 'medelement_move_request')
    command
  end

  it 'applies the move when the read-back later shows an ambiguous write went through' do
    allow(client).to receive(:move_reception).and_raise(
      Integrations::Medelement::Client::ApiError.new('Medelement reception move request failed', status: 503, ambiguous: true)
    )
    command = unresolved_command!
    allow(client).to receive(:get_reception).and_return(reception_readback(requested_starts_at, requested_ends_at))

    command = reconcile!(command)

    expect(command).to be_succeeded
    expect(appointment.reload).to have_attributes(starts_at: requested_starts_at, ends_at: requested_ends_at)
    expect(client).to have_received(:move_reception).once
  end

  it 'applies the move at once when the provider answers OK, although its read still shows the old interval' do
    allow(client).to receive(:move_reception).and_return({})

    command = execute_move!

    expect(command).to be_succeeded
    expect(appointment.reload).to have_attributes(starts_at: requested_starts_at, ends_at: requested_ends_at)
    expect(appointment.custom_attributes).not_to have_key('medelement_move_request')
    expect(client).to have_received(:move_reception).once
    expect(client).to have_received(:get_reception).once
  end

  it 'fails an explicit rejection without a read-back and keeps the confirmed interval' do
    allow(client).to receive(:move_reception).and_raise(Integrations::Medelement::Client::ApiError.new('rejected', status: 400))

    command = execute_move!

    expect(command).to be_failed
    expect(appointment.reload).to have_attributes(starts_at: original_starts_at, ends_at: original_ends_at)
    expect(appointment.custom_attributes['medelement_move_request']).to include('state' => 'rejected', 'evidence' => 'provider_rejected')
    expect(client).to have_received(:move_reception).once
    expect(client).to have_received(:get_reception).once
  end

  it 'keeps an ambiguous move unresolved while the read still shows the old interval' do
    allow(client).to receive(:move_reception).and_raise(
      Integrations::Medelement::Client::ApiError.new('Medelement reception move request failed', status: 503, ambiguous: true)
    )
    command = unresolved_command!

    command = reconcile!(command)

    expect(command).to be_reconciliation_required
    expect(appointment.reload).to have_attributes(starts_at: original_starts_at, ends_at: original_ends_at)
  end
end
