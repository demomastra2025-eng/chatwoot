require 'rails_helper'

RSpec.describe Scheduling::Appointments::ImportedProviderMutationService do
  include ActiveSupport::Testing::TimeHelpers

  around { |example| travel_to(Time.utc(2026, 4, 19, 20)) { example.run } }

  let(:account) { create(:account).tap { |record| record.enable_features!('scheduling') } }
  let(:actor) { create(:captain_assistant, account: account) }
  let(:owner) { create(:contact, account: account, name: 'Mother', phone_number: '+77000000009') }
  let(:patient) do
    create(:contact, account: account, name: 'Test', last_name: 'Patient', phone_number: nil,
                     identifier: '940720300129', custom_attributes: {
                       Contacts::SharedPhone::CARD_KEY => true, 'iin' => '940720300129',
                       'medelement_patient_code' => 'patient-1'
                     })
  end
  let(:conversation) { create(:conversation, account: account, contact: owner) }
  let(:resource) do
    create(:scheduling_resource, account: account, timezone: 'Asia/Almaty', custom_attributes: {
      'medelement_specialist_code' => 'doctor-1', 'medelement_cabinets' => [{ 'companyCabinetCode' => 'cabinet-1' }]
    })
  end
  let(:service) do
    create(:scheduling_service, account: account, custom_attributes: { 'medelement_nomenclature_code' => 'service-1' })
  end
  let(:starts_at) { Time.find_zone!('Asia/Almaty').local(2026, 4, 20, 10) }
  let(:appointment) do
    create(:scheduling_appointment, account: account, resource: resource, service: service, contact: owner,
                                    patient_contact: patient, conversation: conversation, source: 'medelement',
                                    external_ref: 'medelement:reception:reception-1',
                                    starts_at: starts_at - 1.hour, ends_at: starts_at - 30.minutes,
                                    client_name: 'Test Patient', client_first_name: 'Test', client_last_name: 'Patient',
                                    client_identifier: patient.identifier, client_phone: owner.phone_number,
                                    custom_attributes: {
                                      Integrations::Medelement::AppointmentPatientIdentity::OWNED_IDENTITY_KEY => true,
                                      'medelement_patient_code' => 'patient-1', 'medelement_reception_code' => 'reception-1',
                                      'medelement_cabinet_code' => 'cabinet-1'
                                    })
  end
  let(:hook_settings) { attributes_for(:integrations_hook, :medelement)[:settings].merge('write_enabled' => true) }
  let(:hook) { create(:integrations_hook, :medelement, account: account, settings: hook_settings) }
  let(:client) { instance_double(Integrations::Medelement::Client, get_receptions: []) }
  let(:params) { { starts_at: starts_at.iso8601, ends_at: (starts_at + 75.minutes).iso8601 } }
  let(:appointment_access) do
    { token: Captain::Tools::Agent::AppointmentAccess.issue(assistant: actor, conversation: conversation, appointment: appointment),
      conversation_id: conversation.id, patient_confirmed: true }
  end

  before do
    allow(Integrations::Medelement::CronScheduleService).to receive(:new)
      .and_return(instance_double(Integrations::Medelement::CronScheduleService, sync!: true))
    allow(Integrations::Medelement::Client).to receive(:new).and_return(client)
    allow(client).to receive(:timetable) { provider_timetable }
    hook
    appointment.reload
    actor
    appointment_access
  end

  def provider_timetable
    date = starts_at.strftime('%d.%m.%Y')
    { date => { 'timetable' => [{ 'start' => "#{date} 09:00", 'end' => "#{date} 12:00", 'working' => true }] } }
  end

  def perform(operation: 'move_reception', params: self.params, actor: self.actor, appointment_access: self.appointment_access)
    described_class.new(appointment: appointment, actor: actor, operation: operation,
                        params: params, appointment_access: appointment_access).perform
  end

  def expect_scheduling_error(code, &block)
    expect(&block).to raise_error do |error|
      expect(error.class.name).to eq('Scheduling::Error')
      expect(error.code).to eq(code)
    end
  end

  it 'reads the entire interval before locking and queues confirmation after releasing the mutation lock' do
    original = appointment.attributes
    mutation_depth = 0
    allow(appointment).to receive(:with_lock).and_wrap_original do |method, &block|
      method.call do
        mutation_depth += 1
        begin
          block.call
        ensure
          mutation_depth -= 1
        end
      end
    end
    allow(client).to receive(:timetable) do
      expect(mutation_depth).to eq(0)
      provider_timetable
    end
    expect(Integrations::Medelement::ProviderCommands::AutoConfirmationService).to receive(:new)
      .and_wrap_original do |method, **options|
        expect(mutation_depth).to eq(0)
        method.call(**options)
      end

    result = perform
    command = result.medelement_provider_command_receipt

    expect(command.request_snapshot).to include('patient_contact_id' => patient.id, 'provider_patient_code' => 'patient-1',
                                              'actor' => { 'type' => 'Captain::Assistant', 'id' => actor.id })
    expect(command).to have_attributes(requested_by: nil, operation: 'move_reception',
                                      desired_starts_at: starts_at, desired_ends_at: starts_at + 75.minutes)
    expect(command.confirmation_request).to be_confirmed
    expect(appointment.reload.attributes).to eq(original)
  end

  it 'excludes only the original reception when extending its interval' do
    date = starts_at.strftime('%d.%m.%Y')
    allow(client).to receive(:get_receptions).and_return([
      { 'RECEPTION_CODE' => 'reception-1', 'REMOVED' => 0, 'STARTTIME' => "#{date} 09:00", 'ENDTIME' => "#{date} 09:30" }
    ])

    result = perform(params: { starts_at: appointment.starts_at.iso8601, duration_min: 75 })

    expect(result.medelement_provider_command_receipt).to have_attributes(desired_starts_at: appointment.starts_at,
                                                                        desired_ends_at: appointment.starts_at + 75.minutes)
    expect(appointment.reload.duration_min).to eq(30)
  end

  it 'rejects a provider reception occupying the manually extended tail' do
    date = starts_at.strftime('%d.%m.%Y')
    allow(client).to receive(:get_receptions).and_return([
      { 'RECEPTION_CODE' => 'other', 'REMOVED' => 0, 'STARTTIME' => "#{date} 11:00", 'ENDTIME' => "#{date} 11:30" }
    ])

    expect_scheduling_error('APPOINTMENT_SLOT_UNAVAILABLE') { perform }
    expect(Integrations::Medelement::ProviderCommand.where(appointment: appointment)).to be_empty
    expect(appointment.reload.starts_at).to eq(starts_at - 1.hour)
  end

  it 'does not fill a gap in the confirmed provider graph with a local work rule' do
    create(:scheduling_work_rule, resource: resource, weekday: starts_at.wday, start_minute: 0, end_minute: 1440)
    date = starts_at.strftime('%d.%m.%Y')
    allow(client).to receive(:timetable).and_return(
      date => { 'timetable' => [
        { 'start' => "#{date} 09:00", 'end' => "#{date} 10:30", 'working' => true },
        { 'start' => "#{date} 11:00", 'end' => "#{date} 12:00", 'working' => true }
      ] }
    )

    expect_scheduling_error('APPOINTMENT_SLOT_UNAVAILABLE') { perform }
    expect(Integrations::Medelement::ProviderCommand.where(appointment: appointment)).to be_empty
  end

  it 'checks a local occupied tail under the resource lock after the provider read' do
    allow(client).to receive(:timetable) do
      create(:scheduling_appointment, account: account, resource: resource,
                                      starts_at: starts_at + 1.hour, ends_at: starts_at + 90.minutes)
      provider_timetable
    end

    expect_scheduling_error('SLOT_CONFLICT') { perform }
    expect(Integrations::Medelement::ProviderCommand.where(appointment: appointment)).to be_empty
  end

  it 'rejects a signed task when the patient binding changes during the provider read' do
    other_patient = create(:contact, account: account)
    allow(client).to receive(:timetable) do
      account.scheduling_appointments.find(appointment.id).update!(patient_contact: other_patient)
      provider_timetable
    end

    expect_scheduling_error('APPOINTMENT_ACCESS_CHANGED') { perform }
    expect(appointment.reload.patient_contact_id).to eq(other_patient.id)
    expect(Integrations::Medelement::ProviderCommand.where(appointment: appointment)).to be_empty
  end

  it 'rejects changed specialist mapping even when the signed task still names the same resource' do
    allow(client).to receive(:timetable) do
      resource.update!(custom_attributes: resource.custom_attributes.merge('medelement_specialist_code' => 'doctor-2'))
      provider_timetable
    end

    expect_scheduling_error('APPOINTMENT_ACCESS_CHANGED') { perform }
    expect(Integrations::Medelement::ProviderCommand.where(appointment: appointment)).to be_empty
  end

  it 'requires patient confirmation again under the appointment lock' do
    expect_scheduling_error('APPOINTMENT_ACCESS_CHANGED') do
      perform(appointment_access: appointment_access.merge(patient_confirmed: false))
    end
    expect(Integrations::Medelement::ProviderCommand.where(appointment: appointment)).to be_empty
  end

  it 'does not accept a bare assistant or call the provider without a signed task' do
    expect(client).not_to receive(:timetable)
    expect_scheduling_error('APPOINTMENT_ACCESS_CHANGED') { perform(appointment_access: nil) }
  end

  it 'does not admit a user from another account' do
    foreign_user = create(:user)
    expect(client).not_to receive(:timetable)
    expect_scheduling_error('APPOINTMENT_ACCESS_CHANGED') { perform(actor: foreign_user, appointment_access: nil) }
  end

  it 'keeps the ordinary requester association for an account member acting through Copilot' do
    user = create(:user, account: account)

    command = perform(actor: user, appointment_access: nil).medelement_provider_command_receipt

    expect(command.requested_by).to eq(user)
    expect(command.request_snapshot['actor']).to eq('type' => 'User', 'id' => user.id)
    expect(appointment.reload.patient_contact_id).to eq(patient.id)
    expect(owner.reload.phone_number).to eq('+77000000009')
  end

  [{ resource_id: 1 }, { service_id: 1 }, { client_comment: 'changed' }].each do |forbidden|
    it "keeps imported #{forbidden.keys.first} provider owned" do
      expect(client).not_to receive(:timetable)
      expect_scheduling_error('APPOINTMENT_READ_ONLY') { perform(params: params.merge(forbidden)) }
    end
  end

  [0, 1, 2000, 10.5].each do |duration|
    it "rejects invalid duration #{duration} before any provider read" do
      expect(client).not_to receive(:timetable)
      expect { perform(params: { starts_at: starts_at.iso8601, duration_min: duration }) }.to raise_error(ArgumentError)
    end
  end

  it 'cancels only locally while reception removal is disabled and keeps the provider reference' do
    expect(Integrations::Medelement::ProviderCommands::CreateService).not_to receive(:new)
    expect(client).not_to receive(:timetable)

    result = perform(operation: 'remove_reception', params: {})

    expect(result).to have_attributes(status: 'cancelled', source: 'medelement', patient_contact_id: patient.id,
                                     contact_id: owner.id, external_ref: 'medelement:reception:reception-1')
    expect(Integrations::Medelement::LocalCancellation.marked?(result)).to be(true)
    expect(Integrations::Medelement::ProviderCommand.where(appointment: appointment)).to be_empty
    expect(owner.reload.phone_number).to eq('+77000000009')
  end

  it 'queues an opted in removal without claiming that the local appointment has already been cancelled' do
    hook.update!(settings: hook.settings.merge('remove_reception_on_cancel' => true))
    original = appointment.attributes
    expect(client).not_to receive(:timetable)

    result = perform(operation: 'remove_reception', params: {})

    expect(result.medelement_provider_command_receipt).to have_attributes(operation: 'remove_reception',
                                                                        provider_reception_code: 'reception-1')
    expect(result.medelement_provider_command_receipt.confirmation_request).to be_confirmed
    expect(appointment.reload.attributes).to eq(original)
  end

  it 'keeps writes disabled before attempting to prove or stage a move' do
    hook.update!(settings: hook.settings.merge('write_enabled' => false))
    expect(client).not_to receive(:timetable)

    expect_scheduling_error('MEDELEMENT_WRITE_DISABLED') { perform }
    expect(Integrations::Medelement::ProviderCommand.where(appointment: appointment)).to be_empty
  end
end
