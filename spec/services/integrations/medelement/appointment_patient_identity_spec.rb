require 'rails_helper'

RSpec.describe Integrations::Medelement::AppointmentPatientIdentity do
  let(:account) { create(:account).tap { |record| record.enable_features!('scheduling') } }
  let(:contact) do
    create(:contact, account: account, name: 'Primary', last_name: 'Patient', middle_name: 'Parent',
                     identifier: '940720300119', phone_number: '+77000000001', email: 'primary@example.test',
                     custom_attributes: { 'medelement_patient_code' => 'primary-1', 'iin' => '940720300119',
                                          'birth_date' => '1994-07-20', 'gender' => 'male' })
  end
  let(:resource) do
    create(:scheduling_resource, account: account,
                                 custom_attributes: { 'medelement_specialist_code' => 'specialist-1',
                                                      'medelement_cabinets' => [{ 'companyCabinetCode' => 'cabinet-1' }] })
  end
  let(:starts_at) { 2.days.from_now.change(hour: 10, min: 0, sec: 0) }
  let(:appointment) do
    create(:scheduling_appointment, account: account, contact: contact, resource: resource, service: nil,
                                    starts_at: starts_at, ends_at: starts_at + 30.minutes,
                                    client_first_name: 'Relative', client_last_name: 'Patient', client_middle_name: nil,
                                    client_name: 'Relative Patient', client_phone: contact.phone_number,
                                    client_identifier: '940720300129',
                                    custom_attributes: { described_class::EXPLICIT_IDENTIFIER_KEY => true,
                                                         described_class::OWNED_IDENTITY_KEY => true,
                                                         'medelement_cabinet_code' => 'cabinet-1' })
  end
  let(:hook) { build_stubbed(:integrations_hook, account: account, app_id: 'medelement', settings: { 'organization_id' => 'company-1' }) }
  let(:snapshot) do
    Integrations::Medelement::ProviderCommands::RequestSnapshotBuilder.new(
      account: account, hook: hook, operation: 'create_reception', appointment: appointment, contact: contact,
      company_cabinet_code: 'cabinet-1', desired_starts_at: appointment.starts_at, desired_ends_at: appointment.ends_at
    ).build
  end
  let(:command) do
    Integrations::Medelement::ProviderCommand.create!(
      account: account, appointment: appointment, contact: contact, operation: 'create_reception', status: 'processing',
      company_cabinet_code: 'cabinet-1', desired_starts_at: appointment.starts_at, desired_ends_at: appointment.ends_at,
      idempotency_key: SecureRandom.uuid, execution_state: { 'request_snapshot' => snapshot }
    )
  end

  def save_patient(params)
    Scheduling::Appointments::UpsertService.new(account: account, appointment: appointment, params: params).perform
  end

  context 'when creating a new appointment with authored names and no identifier key' do
    let(:appointment) do
      build(:scheduling_appointment, account: account, contact: contact, resource: resource, service: nil,
                                     starts_at: starts_at, ends_at: starts_at + 30.minutes,
                                     client_first_name: nil, client_last_name: nil, client_middle_name: nil,
                                     client_identifier: nil, client_birth_date: nil, client_gender: nil,
                                     custom_attributes: { 'medelement_cabinet_code' => 'cabinet-1' })
    end

    def create_patient(params)
      service = Scheduling::Appointments::UpsertService.new(account: account, appointment: appointment, params: params)
      allow(service).to receive(:validate_availability!)
      allow(service).to receive(:validate_provider_availability!)
      service.perform
    end

    it 'keeps a new relative separate from the primary contact IIN, demographics and provider reference' do
      create_patient(client_first_name: 'Relative', client_last_name: 'Patient')
      expect(appointment.reload).to have_attributes(client_first_name: 'Relative', client_middle_name: nil,
                                                    client_identifier: nil, client_birth_date: nil, client_gender: nil)
      expect(appointment.custom_attributes[described_class::OWNED_IDENTITY_KEY]).to be(true)
      expect(appointment.custom_attributes[described_class::EXPLICIT_IDENTIFIER_KEY]).not_to be(true)
      expect(snapshot).not_to have_key('provider_patient_code')
      expect(snapshot.fetch('patient').fetch('payload')).not_to include('iin', 'birthday', 'gender', 'patient_email')
      expect(contact.reload.identifier).to eq('940720300119')
    end

    it 'keeps positively matching names on the original contact identity' do
      create_patient(client_first_name: contact.name, client_last_name: contact.last_name, client_middle_name: contact.middle_name)
      expect(appointment.custom_attributes[described_class::OWNED_IDENTITY_KEY]).not_to be(true)
      expect(appointment.reload.client_identifier).to eq(contact.identifier)
      expect(snapshot['provider_patient_code']).to eq('primary-1')
    end
  end

  it 'preserves an existing unmarked record when authored names omit the identifier key' do
    appointment.update!(custom_attributes: { 'medelement_cabinet_code' => 'cabinet-1' })
    save_patient(client_first_name: 'Legacy')
    expect(appointment.reload.client_first_name).to eq('Legacy')
    expect(appointment.custom_attributes[described_class::OWNED_IDENTITY_KEY]).not_to be(true)
    expect(appointment.custom_attributes[described_class::EXPLICIT_IDENTIFIER_KEY]).not_to be(true)
  end

  it 'freezes separate identity without primary contact code, IIN, email or demographics' do
    appointment.update!(client_identifier: nil)
    expect(snapshot).not_to have_key('provider_patient_code')
    expect(snapshot.dig('patient', 'payload')).to include('name' => 'Relative', 'lastname' => 'Patient')
    expect(snapshot.fetch('patient').fetch('payload')).not_to include('iin', 'birthday', 'gender', 'patient_email')
    expect(snapshot.fetch(described_class::SNAPSHOT_KEY)).to eq(described_class.current_snapshot(appointment))
  end

  it 'uses the appointment provider reference when the chat contact belongs to another patient' do
    appointment.update!(custom_attributes: appointment.custom_attributes.merge('medelement_patient_code' => 'relative-2'))
    expect(snapshot['provider_patient_code']).to eq('relative-2')
    expect(described_class.provider_code(appointment: appointment, contact: contact)).to eq('relative-2')
  end

  %w[create_patient update_patient create_reception move_reception].each do |operation|
    it "uses only the separate appointment phone for #{operation}" do
      appointment.update!(client_phone: '+77000000002')
      contact.update!(custom_attributes: contact.custom_attributes.merge('secondary_phones' => ['+77000000003']))
      if operation == 'update_patient'
        appointment.update!(custom_attributes: appointment.custom_attributes.merge('medelement_patient_code' => 'relative-2'))
      end
      result = Integrations::Medelement::ProviderCommands::RequestSnapshotBuilder.new(
        account: account, hook: hook, operation: operation, appointment: appointment, contact: contact,
        company_cabinet_code: 'cabinet-1', desired_starts_at: appointment.starts_at, desired_ends_at: appointment.ends_at
      ).build
      expect(result['patient_phone_numbers']).to eq(['+77000000002'])
      next if operation == 'move_reception'

      expect(result.fetch('patient')).to include('phone_number' => '+77000000002', 'phone_numbers' => ['+77000000002'])
      expect(result.dig('patient', 'payload')).to include('patient_phone_2[0]' => '7', 'patient_phone_2[1]' => '700',
                                                          'patient_phone_2[2]' => '0000002')
      expect(contact.reload.phone_number).to eq('+77000000001')
    end
  end

  it 'freezes the separate desired appointment phone rather than a contact phone change' do
    result = Integrations::Medelement::ProviderCommands::RequestSnapshotBuilder.new(
      account: account, hook: hook, operation: 'create_patient', appointment: appointment, contact: contact,
      desired_attributes: { 'client_phone' => '+77000000002', 'phone_number' => '+77000000003' }
    ).build
    expect(result.dig(described_class::SNAPSHOT_KEY, 'fields', 'client_phone')).to eq('+77000000002')
    expect(result['patient_phone_numbers']).to eq(['+77000000002'])
    expect(result.dig('patient', 'phone_number')).to eq('+77000000002')
  end

  it 'rejects an explicitly cleared separate appointment phone despite a valid contact phone' do
    builder = Integrations::Medelement::ProviderCommands::RequestSnapshotBuilder.new(
      account: account, hook: hook, operation: 'update_patient', appointment: appointment, contact: contact,
      desired_attributes: { 'client_phone' => nil }
    )
    expect { builder.build }.to raise_error(Scheduling::Error) { |error| expect(error.code).to eq('MEDELEMENT_PATIENT_PHONE_INVALID') }
  end

  [{}, { described_class::OWNED_IDENTITY_KEY => false, described_class::EXPLICIT_IDENTIFIER_KEY => false }].each do |attributes|
    it "rejects a delayed source that drops protected identity flags: #{attributes}" do
      builder = Integrations::Medelement::ProviderCommands::RequestSnapshotBuilder.new(
        account: account, hook: hook, operation: 'create_reception', appointment: appointment, contact: contact,
        desired_attributes: { 'custom_attributes' => attributes }
      )
      expect { builder.build }.to raise_error(Scheduling::Error) do |error|
        expect(error.code).to eq('MEDELEMENT_PATIENT_IDENTITY_CONFLICT')
      end
    end
  end

  it 'preserves a valid captured identity and reference without rebuilding its authored values' do
    attributes = appointment.custom_attributes.merge('medelement_patient_code' => 'relative-2')
    result = Integrations::Medelement::ProviderCommands::RequestSnapshotBuilder.new(
      account: account, hook: hook, operation: 'create_reception', appointment: appointment, contact: contact,
      desired_attributes: { 'custom_attributes' => attributes, 'client_identifier' => nil }
    ).build
    expect(result['provider_patient_code']).to eq('relative-2')
    expect(result.dig(described_class::SNAPSHOT_KEY, 'fields', 'client_identifier')).to be_nil
    expect(result.dig(described_class::SNAPSHOT_KEY, 'owned')).to be(true)
  end

  def remove_legacy_identity_snapshot
    command.update!(execution_state: command.execution_state.merge(
      'request_snapshot' => command.request_snapshot.except(described_class::SNAPSHOT_KEY)
    ))
  end

  it 'rejects a legacy staff command after the appointment acquires protected identity before looking up a patient' do
    remove_legacy_identity_snapshot
    client = instance_double(Integrations::Medelement::Client)
    expect(described_class.current?(command)).to be(false)
    expect(Integrations::Medelement::ProviderCommands::ReceptionDiscoveryGuard.new(command: command).current_booking?).to be(false)
    resolver = Integrations::Medelement::ProviderCommands::PatientResolver.new(command: command, client: client, organization_id: 'company-1')
    expect { resolver.resolve!(allow_create: true) }.to raise_error(Integrations::Medelement::ProviderCommands::ExecutionError)
  end

  it 'rejects late legacy patient and reception results without changing either local identity' do
    remove_legacy_identity_snapshot
    before_contact = contact.reload.attributes.deep_dup
    applier = Integrations::Medelement::ProviderCommands::SuccessApplier.new(command: command)
    expect { applier.patient!(patient_code: 'primary-1') }.to raise_error(Scheduling::Error)
    expect { applier.reception_created!(reception_code: 'legacy-1', patient_code: 'primary-1') }.to raise_error(Scheduling::Error)
    expect(contact.reload.attributes).to eq(before_contact)
    expect(appointment.reload.external_ref).to be_nil
    expect(appointment.custom_attributes['medelement_patient_code']).to be_nil
  end

  it 'does not write a primary contact when a legacy lookup returns after ownership changes' do
    appointment.update!(custom_attributes: { 'medelement_cabinet_code' => 'cabinet-1' })
    contact.update!(custom_attributes: contact.custom_attributes.except('medelement_patient_code'))
    command
    patient = { 'PROFILE_CODE' => 'relative-2', 'NAME' => 'Relative', 'LASTNAME' => 'Patient',
                'IIN' => appointment.client_identifier, 'PATIENT_PHONE_2' => contact.phone_number, 'COMPANY_CODE' => 'company-1' }
    client = instance_double(Integrations::Medelement::Client)
    before_contact = contact.reload.attributes.deep_dup
    allow(client).to receive(:search_patients_by_iin) do
      appointment.update!(custom_attributes: appointment.custom_attributes.merge(described_class::OWNED_IDENTITY_KEY => true))
      [patient]
    end
    resolver = Integrations::Medelement::ProviderCommands::PatientResolver.new(command: command, client: client, organization_id: 'company-1')
    expect { resolver.resolve!(allow_create: false) }.to raise_error(Integrations::Medelement::ProviderCommands::ExecutionError)
    expect(contact.reload.attributes).to eq(before_contact)
    expect(command.reload.provider_patient_code).to be_nil
  end

  %w[create_patient update_patient create_reception move_reception].each do |operation|
    it "does not publish a legacy #{operation} write phase against a newly protected patient" do
      remove_legacy_identity_snapshot
      command.update!(operation: operation, status: 'queued')
      executor = Integrations::Medelement::ProviderCommands::Executor.new(command: command)
      expect(executor.send(:claim!)).to be(true)
      expect { executor.send(:mark_write_phase!, 'patient_create') }
        .to raise_error(Integrations::Medelement::ProviderCommands::ExecutionError)
      expect(command.reload.execution_state).not_to have_key('write_phase')
    end
  end

  it 'rejects adopting identity flags after an unfrozen legacy write started even if all identity fields stay the same' do
    appointment.update!(custom_attributes: { 'medelement_cabinet_code' => 'cabinet-1' })
    command.update!(execution_state: command.execution_state.merge('write_phase' => 'patient_create'))
    before_identity = appointment.attributes.slice(*described_class::FIELDS)
    expect { save_patient(client_identifier: appointment.client_identifier) }.to raise_error(Scheduling::Error) do |error|
      expect(error.code).to eq('MEDELEMENT_BOOKING_REQUIRES_VERIFICATION')
    end
    expect(appointment.reload.attributes.slice(*described_class::FIELDS)).to eq(before_identity)
    expect(appointment.custom_attributes[described_class::EXPLICIT_IDENTIFIER_KEY]).not_to be(true)
    expect(appointment.custom_attributes[described_class::OWNED_IDENTITY_KEY]).not_to be(true)
  end

  context 'when a legacy booking already published its provider write' do
    before do
      appointment.update!(client_first_name: contact.name, client_last_name: contact.last_name, client_middle_name: contact.middle_name,
                          client_name: [contact.name, contact.last_name, contact.middle_name].join(' '),
                          client_identifier: contact.identifier, client_birth_date: Date.new(1994, 7, 20), client_gender: 'male',
                          external_ref: 'medelement:reception:legacy-1',
                          custom_attributes: { 'medelement_cabinet_code' => 'cabinet-1', 'medelement_patient_code' => 'primary-1' })
      command.update!(provider_patient_code: 'primary-1', provider_reception_code: 'legacy-1',
                      execution_state: command.execution_state.merge('write_phase' => 'reception_create'))
    end

    it 'allows a comment-only sidebar save to adopt explicit identity after a successful legacy booking' do
      command.update!(status: 'succeeded')
      before_fields = appointment.reload.attributes.slice(*described_class::FIELDS)
      before_contact = contact.reload.attributes.deep_dup
      save_patient(client_identifier: appointment.client_identifier, client_comment: 'Updated comment')
      expect(appointment.reload.client_comment).to eq('Updated comment')
      expect(appointment.attributes.slice(*described_class::FIELDS)).to eq(before_fields)
      expect(appointment.custom_attributes[described_class::EXPLICIT_IDENTIFIER_KEY]).to be(true)
      expect(appointment.custom_attributes[described_class::OWNED_IDENTITY_KEY]).not_to be(true)
      expect(appointment.external_ref).to eq('medelement:reception:legacy-1')
      expect(appointment.custom_attributes['medelement_patient_code']).to eq('primary-1')
      expect(contact.reload.attributes).to eq(before_contact)
    end

    %w[processing failed reconciliation_required].each do |status|
      it "does not adopt explicit identity during a #{status} legacy provider write" do
        command.update!(status: status)
        expect { save_patient(client_identifier: appointment.client_identifier, client_comment: 'Updated comment') }
          .to raise_error(Scheduling::Error) { |error| expect(error.code).to eq('MEDELEMENT_BOOKING_REQUIRES_VERIFICATION') }
        expect(appointment.reload.client_comment).not_to eq('Updated comment')
        expect(appointment.custom_attributes[described_class::EXPLICIT_IDENTIFIER_KEY]).not_to be(true)
      end
    end

    it 'keeps patient fields locked after a successful legacy provider write' do
      command.update!(status: 'succeeded')
      expect { save_patient(client_identifier: appointment.client_identifier, client_phone: '+77000000002') }
        .to raise_error(Scheduling::Error) { |error| expect(error.code).to eq('MEDELEMENT_BOOKING_REQUIRES_VERIFICATION') }
      expect(appointment.reload.client_phone).to eq(contact.phone_number)
    end
  end

  it 'persists explicit clearing across a later update with no identifier key' do
    save_patient(client_identifier: nil)
    save_patient(client_comment: 'Updated')
    expect(appointment.reload.client_identifier).to be_nil
    expect(appointment.custom_attributes[described_class::EXPLICIT_IDENTIFIER_KEY]).to be(true)
    expect(snapshot.dig('patient', 'payload')).not_to have_key('iin')
  end

  it 'separates newly authored relative identity and clears inherited demographic fields' do
    appointment.update!(client_first_name: 'Primary', client_last_name: 'Patient', client_middle_name: 'Parent',
                        client_identifier: contact.identifier, client_birth_date: Date.new(1994, 7, 20), client_gender: 'male',
                        custom_attributes: { 'medelement_cabinet_code' => 'cabinet-1' })
    save_patient(client_first_name: 'Relative', client_last_name: 'Patient', client_identifier: nil)
    expect(appointment.reload).to have_attributes(client_first_name: 'Relative', client_middle_name: nil,
                                                  client_identifier: nil, client_birth_date: nil, client_gender: nil)
    expect(appointment.custom_attributes[described_class::OWNED_IDENTITY_KEY]).to be(true)
    expect(contact.reload.identifier).to eq('940720300119')
  end

  it 'keeps a positively matching linked contact when only clearing its appointment identifier' do
    appointment.update!(client_first_name: contact.name, client_last_name: contact.last_name, client_middle_name: contact.middle_name,
                        custom_attributes: { 'medelement_cabinet_code' => 'cabinet-1' })
    save_patient(client_identifier: nil)
    expect(appointment.custom_attributes[described_class::OWNED_IDENTITY_KEY]).not_to be(true)
    expect(snapshot['provider_patient_code']).to eq('primary-1')
  end

  it 'rejects contradictory authored names for the same known IIN' do
    expect { save_patient(client_identifier: contact.identifier) }.to raise_error(Scheduling::Error) do |error|
      expect(error.code).to eq('MEDELEMENT_PATIENT_IDENTITY_CONFLICT')
    end
  end

  it 'rejects retargeting an already linked appointment to another IIN' do
    appointment.update!(custom_attributes: appointment.custom_attributes.merge('medelement_patient_code' => 'relative-2'))
    expect { save_patient(client_identifier: nil) }.to raise_error(Scheduling::Error) do |error|
      expect(error.code).to eq('MEDELEMENT_PATIENT_IDENTITY_CONFLICT')
    end
    expect(appointment.reload.client_identifier).to eq('940720300129')
  end

  it 'rejects forged or cleared server ownership markers through custom attributes' do
    expect { save_patient(custom_attributes: { described_class::OWNED_IDENTITY_KEY => false }) }.to raise_error(Crm::Error)
    expect(appointment.reload.custom_attributes[described_class::OWNED_IDENTITY_KEY]).to be(true)
  end

  it 'resolves a separate IIN without changing any primary contact attributes' do
    client = instance_double(Integrations::Medelement::Client)
    patient = { 'PROFILE_CODE' => 'relative-2', 'NAME' => 'Relative', 'LASTNAME' => 'Patient',
                'IIN' => appointment.client_identifier, 'PATIENT_PHONE_2' => contact.phone_number, 'COMPANY_CODE' => 'company-1' }
    allow(client).to receive(:search_patients_by_iin).and_return([patient])
    before_attributes = contact.reload.attributes.deep_dup
    resolver = Integrations::Medelement::ProviderCommands::PatientResolver.new(command: command, client: client, organization_id: 'company-1')
    expect(resolver.resolve!(allow_create: false)).to eq('relative-2')
    expect(command.reload.provider_patient_code).to eq('relative-2')
    expect(contact.reload.attributes).to eq(before_attributes)
  end

  it 'applies a separate reception to the appointment and keeps the chat contact unchanged' do
    before_attributes = contact.reload.attributes.deep_dup
    Integrations::Medelement::ProviderCommands::SuccessApplier.new(command: command)
                                                              .reception_created!(reception_code: 'reception-2', patient_code: 'relative-2')
    expect(appointment.reload.custom_attributes['medelement_patient_code']).to eq('relative-2')
    expect(appointment.external_ref).to eq('medelement:reception:reception-2')
    expect(command.reload).to be_succeeded
    expect(contact.reload.attributes).to eq(before_attributes)
  end

  { client_first_name: 'Changed', client_identifier: nil, client_birth_date: Date.new(2001, 1, 1),
    client_gender: 'female', client_phone: '+77000000002' }.each do |field, value|
    it "rejects an old provider result after #{field} changes" do
      command
      appointment.update!(field => value)
      guard = Integrations::Medelement::ProviderCommands::ReceptionDiscoveryGuard.new(command: command)
      expect(guard.current_booking?).to be(false)
      expect do
        Integrations::Medelement::ProviderCommands::SuccessApplier.new(command: command)
                                                                  .reception_created!(reception_code: 'reception-2', patient_code: 'relative-2')
      end.to raise_error(Scheduling::Error)
      expect(appointment.reload.external_ref).to be_nil
      expect(contact.reload.custom_attributes['medelement_patient_code']).to eq('primary-1')
    end
  end

  it 'rejects malformed frozen identity and preserves legacy snapshot compatibility' do
    schema = Integrations::Medelement::ProviderCommands::RequestSnapshotSchema
    expect(schema.valid?(snapshot)).to be(true)
    expect(schema.valid?(snapshot.except(described_class::SNAPSHOT_KEY))).to be(true)
    malformed = snapshot.merge(described_class::SNAPSHOT_KEY => { 'owned' => 'true' })
    expect(schema.valid?(malformed)).to be(false)
  end

  it 'publishes a frozen write phase before preventing a concurrent patient identity edit' do
    command.update!(status: 'queued')
    executor = Integrations::Medelement::ProviderCommands::Executor.new(command: command)
    expect(executor.send(:claim!)).to be(true)
    executor.send(:mark_write_phase!, 'patient_create')
    expect(command.reload.execution_state['write_phase']).to eq('patient_create')
    expect { save_patient(client_identifier: nil) }.to raise_error(Scheduling::Error) do |error|
      expect(error.code).to eq('MEDELEMENT_BOOKING_REQUIRES_VERIFICATION')
    end
    expect(appointment.reload.client_identifier).to eq('940720300129')
  end

  it 'does not publish a write phase after the frozen patient was changed' do
    command.update!(status: 'queued')
    executor = Integrations::Medelement::ProviderCommands::Executor.new(command: command)
    expect(executor.send(:claim!)).to be(true)
    appointment.update!(client_identifier: nil)
    expect { executor.send(:mark_write_phase!, 'patient_create') }
      .to raise_error(Integrations::Medelement::ProviderCommands::ExecutionError)
    expect(command.reload.execution_state).not_to have_key('write_phase')
  end

  it 'rechecks an appointment-backed patient creation before writing to the provider' do
    appointment.update!(client_middle_name: 'Member')
    command.update!(operation: 'create_patient', status: 'queued',
                    execution_state: command.execution_state.merge('patient_creation_confirmed' => true))
    client = instance_double(Integrations::Medelement::Client)
    executor = Integrations::Medelement::ProviderCommands::Executor.new(command: command, client: client)
    expect(executor.send(:claim!)).to be(true)
    calls = 0
    allow(client).to receive(:search_patients_by_iin) do
      calls += 1
      appointment.update!(client_identifier: nil) if calls == 2
      []
    end
    allow(client).to receive(:create_patient)
    resolver = Integrations::Medelement::ProviderCommands::PatientResolver.new(
      command: command, client: client, organization_id: 'company-1',
      before_create: -> { executor.send(:mark_write_phase!, 'patient_create') }
    )
    expect { resolver.resolve!(allow_create: true) }.to raise_error(Integrations::Medelement::ProviderCommands::ExecutionError)
    expect(client).not_to have_received(:create_patient)
  end

  [true, false].each do |resolved|
    it "preserves separate identity on background import with resolved contact=#{resolved}" do
      conversation = create(:conversation, account: account, contact: contact)
      appointment.update!(conversation: conversation)
      Integrations::Medelement::ProviderCommands::SuccessApplier.new(command: command)
                                                                .reception_created!(reception_code: 'reception-2', patient_code: 'relative-2')
      appointment.update!(client_identifier: nil)
      before_identity = appointment.reload.attributes.slice(*described_class::FIELDS, 'client_name', 'contact_id', 'conversation_id')
      relative = appointment.reload.patient_contact.tap { |card| card.update!(name: 'Imported', last_name: 'Version') } if resolved
      result = Integrations::Medelement::AppointmentImporterService.new(account: account).upsert!(
        resource: resource, contact: relative, reception: { 'RECEPTION_CODE' => 'reception-2', 'PATIENT_CODE' => 'relative-2', 'ACTIVE' => 1 },
        import_context: { starts_at: appointment.starts_at, ends_at: appointment.ends_at, specialist_code: 'specialist-1' }
      )
      expect(result.reload.attributes.slice(*described_class::FIELDS, 'client_name', 'contact_id', 'conversation_id')).to eq(before_identity)
      expect(contact.reload.custom_attributes['medelement_patient_code']).to eq('primary-1')
    end
  end

  it 'rejects background import of a reception with a conflicting patient code' do
    Integrations::Medelement::ProviderCommands::SuccessApplier.new(command: command)
                                                              .reception_created!(reception_code: 'reception-2', patient_code: 'relative-2')
    expect do
      Integrations::Medelement::AppointmentImporterService.new(account: account).upsert!(
        resource: resource, contact: contact, reception: { 'RECEPTION_CODE' => 'reception-2', 'PATIENT_CODE' => 'primary-1', 'ACTIVE' => 1 },
        import_context: { starts_at: appointment.starts_at, ends_at: appointment.ends_at, specialist_code: 'specialist-1' }
      )
    end.to raise_error(Scheduling::Error) { |error| expect(error.code).to eq('MEDELEMENT_PATIENT_IDENTITY_CONFLICT') }
    expect(appointment.reload.custom_attributes['medelement_patient_code']).to eq('relative-2')
  end
end
