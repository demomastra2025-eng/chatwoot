require 'rails_helper'

RSpec.describe Integrations::Medelement::ProviderCommands::CreateService do
  subject(:perform) { service.perform }

  let(:service) do
    described_class.new(
      account: account,
      hook: hook,
      appointment: appointment,
      operation: 'create_reception',
      idempotency_key: idempotency_key,
      company_cabinet_code: 'cabinet-1',
      actor: user
    )
  end

  let(:account) { create(:account) }
  let(:user) { create(:user, :administrator, account: account) }
  let(:contact) { create(:contact, account: account, name: 'Ivanov Ivan', phone_number: '+77000000001') }
  let(:resource) do
    create(
      :scheduling_resource,
      account: account,
      custom_attributes: {
        'medelement_specialist_code' => 'specialist-1',
        'medelement_cabinets' => [{ 'companyCabinetCode' => 'cabinet-1' }]
      }
    )
  end
  let(:appointment) { create(:scheduling_appointment, account: account, contact: contact, resource: resource) }
  let(:idempotency_key) { 'create-reception-1' }
  let(:hook_settings) { attributes_for(:integrations_hook, :medelement)[:settings].merge('write_enabled' => true) }
  let(:hook) { create(:integrations_hook, :medelement, account: account, settings: hook_settings) }

  before do
    account.enable_features!('scheduling')
    schedule_service = instance_double(Integrations::Medelement::CronScheduleService, sync!: true)
    allow(Integrations::Medelement::CronScheduleService).to receive(:new).and_return(schedule_service)
  end

  it 'persists an awaiting-confirmation command without executing the provider write', :aggregate_failures do
    command = perform

    expect(command.status).to eq('v2_awaiting_confirmation')
    expect(command).to be_awaiting_confirmation
    expect(Integrations::Medelement::ProviderCommand.where(status: 'awaiting_confirmation')).not_to exist(command.id)
    expect(Integrations::Medelement::ProviderCommandPayloadBuilder.build(command)[:status]).to eq('awaiting_confirmation')
    expect(command.confirmation_request).to be_pending
    expect(command.confirmation_request.metadata).to include(
      'medelement_provider_command_id' => command.id,
      'operation' => 'create_reception',
      'request_fingerprint' => command.execution_state.fetch('request_fingerprint')
    )
    expect(command.execution_state).to include('confirmation_request_id' => command.confirmation_request_id)
    expect(command.confirmation_matches_request_snapshot?).to be(true)
    expect(command.confirmation_request.body).to include(
      command.request_snapshot.dig('reception', 'destination_starts_at'),
      'пациент Ivanov Ivan',
      '(specialist-1)',
      'длительность 30 мин',
      'кабинет cabinet-1',
      'команда остановится для выбора пациента или отдельного подтверждения создания',
      'локальный контакт не создаётся'
    )
    expect(command).to have_attributes(
      account: account,
      hook: hook,
      appointment: appointment,
      contact: contact,
      company_cabinet_code: 'cabinet-1',
      attempt_count: 0
    )
  end

  it 'uses the appointment phone when the contact phone is blank without mutating the contact' do
    appointment_phone = ['+7', '700', '123', '4567'].join
    contact.update!(phone_number: nil)
    appointment.update!(client_phone: appointment_phone)

    command = perform

    expect(command.request_snapshot).to include('patient_phone_numbers' => [appointment_phone])
    expect(command.request_snapshot.fetch('patient')).to include(
      'phone_number' => appointment_phone,
      'phone_numbers' => [appointment_phone],
      'payload' => include(
        'patient_phone_2[0]' => '7',
        'patient_phone_2[1]' => '700',
        'patient_phone_2[2]' => '1234567'
      )
    )
    expect(contact.reload.phone_number).to be_nil
  end

  it 'does not mix a stale contact phone into a reception created with an appointment phone' do
    stale_contact_phone = ['+7', '700', '000', '0002'].join
    appointment_phone = ['+7', '700', '123', '4567'].join
    contact.update!(phone_number: stale_contact_phone)
    appointment.update!(client_phone: '8 (700) 123-45-67')

    command = perform

    expect(command.request_snapshot).to include('patient_phone_numbers' => [appointment_phone])
    expect(command.request_snapshot.fetch('patient')).to include(
      'phone_number' => appointment_phone,
      'phone_numbers' => [appointment_phone]
    )
    expect(contact.reload.phone_number).to eq(stale_contact_phone)
  end

  it 'uses the linked Contact patient code and ignores appointment identity snapshots' do
    contact.update!(
      name: 'Unknown',
      phone_number: nil,
      custom_attributes: { 'medelement_patient_code' => 'patient-old' }
    )
    appointment.update!(
      client_name: 'Gusman Assem',
      client_phone: '+77001234567',
      client_identifier: '940720300129',
      client_birth_date: Date.new(1994, 7, 20),
      client_gender: 'female'
    )
    contact_count = account.contacts.count

    command = perform

    expect(command.request_snapshot).not_to have_key('patient')
    expect(command).to have_attributes(provider_patient_code: 'patient-old')
    expect(command.request_snapshot['provider_patient_code']).to eq('patient-old')
    expect(contact.reload).to have_attributes(name: 'Unknown', phone_number: nil)
    expect(contact.custom_attributes['medelement_patient_code']).to eq('patient-old')
    expect(account.contacts.count).to eq(contact_count)
  end

  it 'persists the complete old-to-new move details in the confirmation audit body' do
    scheduling_service = create(:scheduling_service, account: account, name: 'Консультация')
    contact.update!(custom_attributes: contact.custom_attributes.merge('medelement_patient_code' => 'patient-1'))
    appointment.update!(
      service: scheduling_service,
      service_name_snapshot: 'Консультация',
      service_amount: 15_000,
      duration_min: 45,
      external_ref: 'medelement:reception:reception-1'
    )
    new_starts_at = appointment.starts_at + 1.day
    new_ends_at = appointment.ends_at + 1.day

    command = described_class.new(
      account: account,
      hook: hook,
      appointment: appointment,
      operation: 'move_reception',
      idempotency_key: 'move-reception-audit-1',
      company_cabinet_code: 'cabinet-1',
      actor: user,
      desired_starts_at: new_starts_at,
      desired_ends_at: new_ends_at
    ).perform

    body = command.confirmation_request.body
    expect(body).to include(
      'пациент Ivanov Ivan',
      "специалист #{resource.name} (specialist-1)",
      'услуга Консультация',
      'цена 15000',
      'длительность 45 мин',
      "исходное время #{appointment.starts_at.utc.iso8601(6)} — #{appointment.ends_at.utc.iso8601(6)}",
      "новое время #{new_starts_at.utc.iso8601(6)} — #{new_ends_at.utc.iso8601(6)}"
    )
    expect(command.request_snapshot.fetch('confirmation')).to include(
      'patient_name' => 'Ivanov Ivan',
      'specialist_name' => resource.name,
      'service_name' => 'Консультация',
      'price' => 15_000,
      'duration_min' => 45
    )
  end

  it 'returns the same command for a repeated idempotency key' do
    first = service.perform
    appointment.update!(client_comment: 'Changed after the original request')
    second = service.perform

    expect(second).to eq(first)
    expect(first.id).to eq(second.id)
    expect(Integrations::Medelement::ProviderCommand.where(account: account).count).to eq(1)
    metadata = { 'medelement_provider_command_id' => first.id, 'operation' => 'create_reception' }
    expect(
      ConfirmationRequest.where(account: account).where('metadata @> ?', metadata.to_json).count
    ).to eq(1)
    expect(first.request_snapshot_valid?).to be(true)
    expect(first.execution_state).to include('idempotency_fingerprint')
  end

  it 'rejects reuse of an idempotency key for a different command payload' do
    service.perform

    expect do
      described_class.new(
        account: account,
        hook: hook,
        appointment: appointment,
        operation: 'create_reception',
        idempotency_key: idempotency_key,
        company_cabinet_code: 'cabinet-2',
        actor: user
      ).perform
    end.to raise_error(Scheduling::Error) { |error|
      expect(error.code).to eq('MEDELEMENT_IDEMPOTENCY_KEY_REUSED')
      expect(error.status).to eq(409)
    }
  end

  it 'rejects a second unfinished command for the same appointment' do
    perform

    expect do
      described_class.new(
        account: account,
        hook: hook,
        appointment: appointment,
        operation: 'create_reception',
        idempotency_key: 'create-reception-2',
        company_cabinet_code: 'cabinet-1'
      ).perform
    end.to raise_error(Scheduling::Error) { |error| expect(error.code).to eq('MEDELEMENT_COMMAND_IN_PROGRESS') }
  end

  it 'rejects patient creation through an appointment while a contact command is unfinished' do
    contact.update!(custom_attributes: { 'medelement_patient_code' => 'patient-old' })
    Integrations::Medelement::ProviderCommand.create!(
      account: account,
      hook: hook,
      contact: contact,
      operation: 'create_patient',
      status: 'queued',
      idempotency_key: 'patient-command'
    )

    expect { perform }.to raise_error(Scheduling::Error) { |error| expect(error.code).to eq('MEDELEMENT_COMMAND_IN_PROGRESS') }
  end

  it 'rejects a second unfinished patient update for the same contact' do
    contact.update!(custom_attributes: contact.custom_attributes.merge('medelement_patient_code' => 'patient-1'))
    Integrations::Medelement::ProviderCommand.create!(
      account: account,
      hook: hook,
      contact: contact,
      operation: 'update_patient',
      status: 'queued',
      provider_patient_code: 'patient-1',
      idempotency_key: 'first-patient-update'
    )

    expect do
      described_class.new(
        account: account,
        hook: hook,
        contact: contact,
        operation: 'update_patient',
        idempotency_key: 'second-patient-update'
      ).perform
    end.to raise_error(Scheduling::Error) { |error| expect(error.code).to eq('MEDELEMENT_COMMAND_IN_PROGRESS') }
  end

  it 'rejects a contact that does not match the appointment' do
    other_contact = create(:contact, account: account)

    expect do
      described_class.new(
        account: account,
        hook: hook,
        appointment: appointment,
        contact: other_contact,
        operation: 'create_reception',
        idempotency_key: 'wrong-contact',
        company_cabinet_code: 'cabinet-1'
      ).perform
    end.to raise_error(ArgumentError, 'contact must match the appointment contact')
  end

  it 'fails closed when provider writes are disabled' do
    hook.update!(settings: hook.settings.merge('write_enabled' => false))

    expect { perform }.to raise_error(Scheduling::Error) { |error| expect(error.code).to eq('MEDELEMENT_WRITE_DISABLED') }
    expect(Integrations::Medelement::ProviderCommand.where(account: account)).to be_empty
  end

  it 'rejects an appointment from another account' do
    other_appointment = create(:scheduling_appointment)

    expect do
      described_class.new(
        account: account,
        hook: hook,
        appointment: other_appointment,
        operation: 'create_reception',
        idempotency_key: 'cross-account',
        company_cabinet_code: 'cabinet-1'
      ).perform
    end.to raise_error(ArgumentError, 'appointment must belong to the current account')
  end
end
