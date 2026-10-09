require 'rails_helper'

RSpec.describe Integrations::Medelement::ProviderCommands::PatientSelectionService do
  let(:account) { create(:account).tap { |record| record.enable_features!('scheduling') } }
  let(:actor) { create(:user, account: account, role: :agent) }
  let(:owner_attributes) { { 'unrelated' => 'kept' } }
  let(:owner) { create(:contact, account: account, name: 'Mother', last_name: 'Owner', phone_number: '+77001234567', custom_attributes: owner_attributes) }
  let(:placeholder) do
    create(:contact, account: account, name: 'Child', last_name: 'Patient', phone_number: nil,
                     custom_attributes: {
                       Contacts::SharedPhone::CARD_KEY => true, Contacts::SharedPhone::SHARED_OWNER_KEY => owner.id,
                       Contacts::SharedPhone::SHARED_PHONE_KEY => owner.phone_number,
                       'secondary_phones' => [owner.phone_number]
                     })
  end
  let(:resource) do
    create(:scheduling_resource, account: account, custom_attributes: {
             'medelement_specialist_code' => 'specialist-1', 'medelement_cabinets' => [{ 'companyCabinetCode' => 'cabinet-1' }]
           })
  end
  let(:appointment) do
    create(:scheduling_appointment, account: account, contact: owner, patient_contact: placeholder, resource: resource,
                                    client_name: 'Child Patient', client_first_name: 'Child', client_last_name: 'Patient',
                                    client_identifier: nil, client_phone: owner.phone_number,
                                    custom_attributes: { 'medelement_cabinet_code' => 'cabinet-1',
                                                         Integrations::Medelement::AppointmentPatientIdentity::OWNED_IDENTITY_KEY => true })
  end
  let(:hook) do
    create(:integrations_hook, :medelement, account: account,
                                          settings: attributes_for(:integrations_hook, :medelement)[:settings].merge('write_enabled' => true))
  end
  let(:patient) do
    { 'PROFILE_CODE' => 'patient-selected', 'NAME' => 'Child', 'LASTNAME' => 'Patient',
      'IIN' => '940720300129', 'PATIENT_PHONE_2' => owner.phone_number }
  end
  let(:card) do
    create(:contact, account: account, name: 'Child', last_name: 'Patient', phone_number: nil,
                     custom_attributes: { 'medelement_patient_code' => patient['PROFILE_CODE'], 'medelement_iin' => patient['IIN'] })
  end
  let(:command) do
    record = Integrations::Medelement::ProviderCommands::CreateService.new(
      account: account, hook: hook, appointment: appointment, actor: actor, operation: 'create_reception',
      idempotency_key: 'patient-selection-intent', company_cabinet_code: 'cabinet-1',
      desired_starts_at: appointment.starts_at, desired_ends_at: appointment.ends_at, dispatch_identity: 'original-dispatch'
    ).perform
    record.confirmation_request.update!(status: 'confirmed', resolved_at: Time.current, resolution_source: 'manual', resolved_by: actor)
    record.update!(status: record.status_for_transition('awaiting_patient_selection'), confirmed_at: Time.current,
                   execution_state: record.execution_state.merge('patient_action' => { 'type' => 'patient_selection' }))
    Integrations::Medelement::AppointmentProviderStatus.persist!(appointment, 'pending', command: record)
    record
  end
  let(:client) { instance_double(Integrations::Medelement::Client) }
  let(:actions) { Integrations::Medelement::ProviderCommands::PatientActionsService.new(command: command, actor: actor) }

  before do
    allow(Integrations::Medelement::CronScheduleService).to receive(:new).and_return(instance_double(Integrations::Medelement::CronScheduleService, sync!: true))
    allow(Integrations::Medelement::Client).to receive(:new).and_return(client)
    allow(client).to receive(:search_patients_by_phone).and_return([patient])
  end

  def token
    key = Rails.application.key_generator.generate_key('medelement-patient-candidate', 32)
    OpenSSL::HMAC.hexdigest('SHA256', key, "#{command.account_id}:#{command.id}:#{patient['PROFILE_CODE']}")
  end

  it 'adopts an explicitly selected separate card, preserves the confirmed booking and binds a new receipt', :aggregate_failures do
    selected = card
    original = command.request_snapshot.deep_dup
    old_receipt = command.confirmation_request
    old_fingerprint = command.execution_state['request_fingerprint']
    original_intent = command.execution_state['idempotency_fingerprint']
    owner_before = owner.attributes

    expect { actions.select!(token: token) }.to have_enqueued_job(Integrations::Medelement::ProviderCommandJob).with(command.id)

    expect(appointment.reload).to have_attributes(contact_id: owner.id, patient_contact_id: selected.id, client_identifier: patient['IIN'])
    expect(owner.reload.attributes).to eq(owner_before)
    expect(command.reload).to have_attributes(contact_id: owner.id, provider_patient_code: patient['PROFILE_CODE'])
    expect(command).to be_queued
    mutable_keys = %w[patient_contact_id appointment_patient_identity provider_patient_code patient_phone_numbers patient confirmation]
    expect(command.request_snapshot.except(*mutable_keys)).to eq(original.except(*mutable_keys))
    expect(command.request_snapshot['confirmation'].except('patient_name')).to eq(original['confirmation'].except('patient_name'))
    audit = command.execution_state.fetch('patient_selection_history').last
    expect(audit['request_snapshot']).to eq(original)
    expect(Integrations::Medelement::ProviderCommands::RequestSnapshotBuilder.fingerprint(audit['request_snapshot'])).to eq(old_fingerprint)
    expect(command.execution_state['idempotency_fingerprint']).to eq(original_intent)
    expect(command.execution_state['dispatch_identity']).to eq('original-dispatch')
    expect(command.execution_state['request_fingerprint']).not_to eq(old_fingerprint)
    expect(command.execution_state['selected_patient_token']).to eq(token)
    expect(command.confirmation_request_id).not_to eq(old_receipt.id)
    expect(command.confirmation_request).to have_attributes(status: 'confirmed', resolved_by: actor, resolution_source: 'manual')
    expect(old_receipt.reload.metadata['request_fingerprint']).to eq(old_fingerprint)
    expect(command.execution_state['confirmation_request_id']).to eq(command.confirmation_request_id)
    expect(command.request_snapshot_valid?).to be(true)
    expect(command.confirmation_matches_request_snapshot?).to be(true)
    expect(Integrations::Medelement::AppointmentPatientIdentity.current?(command)).to be(true)
    expect(Integrations::Medelement::AppointmentProviderStatus.bound_to_command?(appointment, command)).to be(true)
    expect(placeholder.reload.custom_attributes['secondary_phones']).not_to include(owner.phone_number)
  end

  it 'makes a repeated selection idempotent without another provider job or confirmation' do
    card
    chosen_token = token
    actions.select!(token: chosen_token)
    expect do
      actions.select!(token: chosen_token)
    end.not_to change(ConfirmationRequest, :count)
    expect do
      actions.select!(token: chosen_token)
    end.not_to have_enqueued_job(Integrations::Medelement::ProviderCommandJob)
  end

  it 'uses the same provider code extraction as the candidate HMAC when the provider sends profile_code' do
    selected = card
    allow(client).to receive(:search_patients_by_phone).and_return([patient.except('PROFILE_CODE').merge('profile_code' => patient['PROFILE_CODE'])])
    actions.select!(token: token)
    expect(appointment.reload.patient_contact_id).to eq(selected.id)
    expect(command.provider_patient_code).to eq(patient['PROFILE_CODE'])
  end

  it 'creates a separate patient card when the selected code has no local card' do
    original_owner = owner.attributes
    actions.select!(token: token)
    selected = appointment.reload.patient_contact
    expect(selected.id).not_to eq(owner.id)
    expect(selected.custom_attributes).to include('medelement_patient_code' => patient['PROFILE_CODE'], 'iin' => patient['IIN'])
    expect(Contacts::SharedPhone.share_of(selected).owner_id).to eq(owner.id)
    expect(owner.reload.attributes).to eq(original_owner)
  end

  it 'keeps the automatic patient reference guard before explicit staff selection' do
    card
    command.update!(execution_state: command.execution_state.merge('selected_patient_token' => token))
    resolver = Integrations::Medelement::ProviderCommands::PatientResolver.new(command: command, client: client,
                                                                              organization_id: Integrations::Medelement::Configuration.new(hook: hook).organization_id)
    expect { resolver.resolve!(allow_create: false) }.to raise_error(Integrations::Medelement::ProviderCommands::ExecutionError) do |error|
      expect(error.code).to eq('patient_ref_conflict')
    end
    expect(appointment.reload.patient_contact_id).to eq(placeholder.id)
  end

  %w[write_phase write_provider_patient_code write_provider_reception_code].each do |marker|
    it "rejects changing the patient after #{marker} was recorded" do
      card
      command.update!(execution_state: command.execution_state.merge(marker => 'written'))
      expect { actions.select!(token: token) }.to raise_error(Scheduling::Error)
      expect(appointment.reload.patient_contact_id).to eq(placeholder.id)
    end
  end

  it 'rejects a finished historical provider write even when the current command has not written' do
    card
    Integrations::Medelement::ProviderCommand.create!(account: account, hook: hook, appointment: appointment, contact: owner,
                                                     operation: 'create_reception', status: 'succeeded', idempotency_key: 'prior-patient-write',
                                                     company_cabinet_code: 'cabinet-1',
                                                     execution_state: { 'write_provider_patient_code' => 'old-written-patient' })
    expect { actions.select!(token: token) }.to raise_error(Scheduling::Error)
    expect(appointment.reload.patient_contact_id).to eq(placeholder.id)
  end

  it 'rejects a changed slot instead of replacing the previously confirmed intent' do
    card
    command
    appointment.update_columns(starts_at: appointment.starts_at + 1.hour, ends_at: appointment.ends_at + 1.hour)
    expect { actions.select!(token: token) }.to raise_error(Scheduling::Error)
    expect(command.reload).to be_awaiting_patient_selection
  end

  it 'rejects a fingerprint replaced while candidates were being fetched' do
    card
    command
    allow(client).to receive(:search_patients_by_phone) do
      Integrations::Medelement::ProviderCommand.find(command.id).update!(execution_state: command.execution_state.merge('request_fingerprint' => 'changed'))
      [patient]
    end
    expect { actions.select!(token: token) }.to raise_error(Scheduling::Error)
    expect(appointment.reload.patient_contact_id).to eq(placeholder.id)
  end

  it 'rejects a selected card with a different recorded strong identity' do
    card.update!(custom_attributes: card.custom_attributes.merge('medelement_iin' => '000101300019'))
    expect { actions.select!(token: token) }.to raise_error(Scheduling::Error)
    expect(appointment.reload.patient_contact_id).to eq(placeholder.id)
  end

  it 'does not adopt a card from another account even when its provider code matches' do
    foreign = create(:contact, name: 'Foreign', custom_attributes: { 'medelement_patient_code' => patient['PROFILE_CODE'] })
    actions.select!(token: token)
    expect(appointment.reload.patient_contact_id).not_to eq(foreign.id)
    expect(appointment.patient_contact.account_id).to eq(account.id)
    expect(foreign.reload.name).to eq('Foreign')
  end

  context 'when the verified existing patient is also the communication owner' do
    let(:owner_attributes) do
      { 'medelement_patient_code' => patient['PROFILE_CODE'], 'medelement_iin' => patient['IIN'],
        'medelement_first_name' => 'Child', 'medelement_last_name' => 'Patient', 'medelement_middle_name' => 'Relative',
        'medelement_birth_date' => '1994-07-20', 'iin' => patient['IIN'], 'secondary_phones' => ['+77007778899'], 'unrelated' => 'kept' }
    end

    it 'reuses the verified owner without changing its profile, clinical history or phone sharing' do
      command.update!(status: 'failed', last_error_code: 'patient_ref_conflict')
      old_receipt = command.confirmation_request
      clinical = create(:scheduling_appointment, account: account, contact: owner, resource: resource,
                                                source: 'medelement', external_ref: 'medelement:reception:old-visit')
      history = Integrations::Medelement::ProviderCommand.create!(account: account, hook: hook, appointment: clinical, contact: owner,
                                                                  operation: 'create_reception', status: 'succeeded', idempotency_key: 'owner-clinical-history',
                                                                  company_cabinet_code: 'cabinet-1',
                                                                  provider_patient_code: patient['PROFILE_CODE'], provider_reception_code: 'old-visit',
                                                                  execution_state: { 'write_phase' => 'reception_create' })
      owner_before = owner.attributes
      clinical_before = clinical.attributes
      history_before = history.attributes
      actions.select!(token: token)
      expect(appointment.reload.patient_contact_id).to eq(owner.id)
      expect(appointment.patient_contact.custom_attributes['medelement_patient_code']).to eq(patient['PROFILE_CODE'])
      expect(appointment.client_middle_name).to eq('Relative')
      expect(appointment.client_birth_date).to eq(Date.new(1994, 7, 20))
      expect(owner.reload.attributes).to eq(owner_before)
      expect(clinical.reload.attributes).to eq(clinical_before)
      expect(history.reload.attributes).to eq(history_before)
      expect(old_receipt.reload).to be_confirmed
      expect(command.confirmation_request.body).to include('Child Patient Relative')
      # The later worker success must preserve the owner and its older clinical targets too.
      command.update!(status: command.status_for_transition('processing'), execution_state: command.execution_state.merge('write_phase' => 'reception_create'))
      Integrations::Medelement::ProviderCommands::SuccessApplier.new(command: command).reception_created!(
        reception_code: 'new-reception', patient_code: patient['PROFILE_CODE']
      )
      expect(owner.reload.attributes).to eq(owner_before)
      expect(clinical.reload.attributes).to eq(clinical_before)
      expect(history.reload.attributes).to eq(history_before)
      expect(command.reload).to be_succeeded
      expect(Integrations::Medelement::AppointmentProviderStatus.bound_to_command?(appointment.reload, command)).to be(true)
    end

    it 'fails closed when the owner code has no provider-recorded strong IIN proof' do
      owner.update!(custom_attributes: owner.custom_attributes.except('medelement_iin'))
      expect { actions.select!(token: token) }.to raise_error(Scheduling::Error)
      expect(owner.reload.custom_attributes['medelement_patient_code']).to eq(patient['PROFILE_CODE'])
      expect(appointment.reload.patient_contact_id).to eq(placeholder.id)
    end

    it 'fails closed when the recorded owner profile contradicts the chosen provider identity' do
      owner.update!(custom_attributes: owner.custom_attributes.merge('medelement_first_name' => 'Different'))
      expect { actions.select!(token: token) }.to raise_error(Scheduling::Error)
      expect(owner.reload.custom_attributes['medelement_patient_code']).to eq(patient['PROFILE_CODE'])
    end

    let(:patient) do
      { 'PROFILE_CODE' => 'patient-selected', 'NAME' => 'Child', 'LASTNAME' => 'Patient',
        'MIDDLENAME' => 'Relative', 'BIRTHDAY' => '20.07.1994', 'IIN' => '940720300129', 'PATIENT_PHONE_2' => '+77001234567' }
    end
  end

  context 'when the original booking has no owned patient binding' do
    let(:appointment) do
      create(:scheduling_appointment, account: account, contact: owner, resource: resource,
                                      client_name: 'Child Patient', client_first_name: 'Child', client_last_name: 'Patient',
                                      client_identifier: nil, client_phone: owner.phone_number, custom_attributes: { 'medelement_cabinet_code' => 'cabinet-1' })
    end

    it 'makes the explicit selection a prewrite owned transition to an existing separate card' do
      chosen = card
      actions.select!(token: token)
      expect(appointment.reload.patient_contact_id).to eq(chosen.id)
      expect(appointment.custom_attributes[Integrations::Medelement::AppointmentPatientIdentity::OWNED_IDENTITY_KEY]).to be(true)
      expect(command.request_snapshot_valid?).to be(true)
      expect(Integrations::Medelement::AppointmentPatientIdentity.current?(command)).to be(true)
    end

    ['female', nil].each do |changed_gender|
      it "rejects changing or clearing a captured patient gender to #{changed_gender.inspect} before adopting a card" do
        chosen = card
        appointment.update!(client_gender: 'male')
        original = command.request_snapshot.deep_dup
        old_confirmation_id = command.confirmation_request_id
        expect(original.dig('patient', 'payload', 'gender')).to eq(2)
        appointment.update_columns(client_gender: changed_gender)
        allow(client).to receive(:search_patients_by_phone).and_return([patient.merge('GENDER' => 1)])

        expect do
          expect { actions.select!(token: token) }.to raise_error(Scheduling::Error)
        end.not_to change(ConfirmationRequest, :count)
        expect(appointment.reload.patient_contact_id).to be_nil
        expect(command.reload.request_snapshot).to eq(original)
        expect(command.confirmation_request_id).to eq(old_confirmation_id)
        expect(command).to be_awaiting_patient_selection
        expect(chosen.reload.custom_attributes['medelement_patient_code']).to eq(patient['PROFILE_CODE'])
      end
    end

    it 'rejects a changed effective gender inferred from a selected IIN when the provider omits GENDER' do
      chosen = card
      chosen.update!(custom_attributes: chosen.custom_attributes.merge('medelement_iin' => '940720400125'))
      chosen_before = chosen.attributes
      appointment.update!(client_gender: 'male')
      original = command.request_snapshot.deep_dup
      old_confirmation_id = command.confirmation_request_id
      appointment.update_columns(client_gender: nil)
      allow(client).to receive(:search_patients_by_phone).and_return([patient.merge('IIN' => '940720400125')])

      expect do
        expect { actions.select!(token: token) }.to raise_error(Scheduling::Error)
      end.not_to change(ConfirmationRequest, :count)
      expect(appointment.reload.patient_contact_id).to be_nil
      expect(appointment.client_identifier).to be_nil
      expect(command.reload.request_snapshot).to eq(original)
      expect(command.confirmation_request_id).to eq(old_confirmation_id)
      expect(command).to be_awaiting_patient_selection
      expect(chosen.reload.attributes).to eq(chosen_before)
    end

    it 'allows a missing authored gender when its rebuilt IIN-derived gender preserves the original confirmation' do
      chosen = card
      appointment.update!(client_gender: 'male')
      expect(command.request_snapshot.dig('patient', 'payload', 'gender')).to eq(2)
      appointment.update_columns(client_gender: nil)

      actions.select!(token: token)

      expect(appointment.reload.patient_contact_id).to eq(chosen.id)
      expect(command.request_snapshot.dig('patient', 'payload', 'gender')).to eq(2)
      expect(command.request_snapshot_valid?).to be(true)
      expect(command.confirmation_matches_request_snapshot?).to be(true)
    end
  end
end
