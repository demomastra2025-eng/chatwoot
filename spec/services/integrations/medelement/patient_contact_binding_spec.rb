require 'rails_helper'

RSpec.describe Integrations::Medelement::PatientContactBinding do
  let(:account) { create(:account).tap { |record| record.enable_features!('scheduling') } }
  let(:owner) do
    create(:contact, account: account, name: 'Primary', last_name: 'Patient', phone_number: '+77000000001',
                     custom_attributes: { 'medelement_patient_code' => 'primary-1' })
  end
  let(:conversation) { create(:conversation, account: account, contact: owner) }
  let(:appointment) do
    create(:scheduling_appointment, account: account, contact: owner, conversation: conversation,
                                    client_first_name: 'Relative', client_last_name: 'Patient', client_middle_name: nil,
                                    client_name: 'Relative Patient', client_phone: owner.phone_number, client_identifier: nil,
                                    custom_attributes: { policy::OWNED_IDENTITY_KEY => true, policy::EXPLICIT_IDENTIFIER_KEY => true })
  end
  let(:policy) { Integrations::Medelement::AppointmentPatientIdentity }

  def bind!(code: nil)
    appointment.with_lock do
      described_class.new(appointment: appointment).prepare!(patient_code: code)
      appointment.save!
    end
    appointment.reload.patient_contact
  end

  def command(snapshot: {}, status: 'processing', code: nil, operation: 'create_reception')
    Integrations::Medelement::ProviderCommand.create!(
      account: account, appointment: appointment, contact: owner, operation: operation, status: status,
      company_cabinet_code: 'cabinet-1',
      provider_patient_code: code, idempotency_key: SecureRandom.uuid,
      execution_state: { 'write_phase' => 'patient_write', 'request_snapshot' => snapshot }
    )
  end

  def patient_snapshot(operation: 'update_patient')
    hook = build_stubbed(:integrations_hook, account: account, app_id: 'medelement', settings: { 'organization_id' => 'company-1' })
    Integrations::Medelement::ProviderCommands::RequestSnapshotBuilder.new(
      account: account, hook: hook, operation: operation, appointment: appointment, contact: owner
    ).build
  end

  it 'creates a stable separate card while preserving the first patient and communication route' do
    owner_attributes = owner.reload.attributes
    card = bind!(code: 'relative-2')
    expect(card.id).not_to eq(owner.id)
    expect(card).to have_attributes(name: 'Relative', last_name: 'Patient', phone_number: nil)
    expect(card.custom_attributes).to include('medelement_patient_code' => 'relative-2', 'secondary_phones' => [owner.phone_number],
                                              described_class::SHARED_OWNER_KEY => owner.id)
    expect(bind!(code: 'relative-2').id).to eq(card.id)
    expect(appointment).to have_attributes(contact_id: owner.id, conversation_id: conversation.id, patient_contact_id: card.id)
    expect(owner.reload.attributes).to eq(owner_attributes)
  end

  it 'reuses the verified provider card and never adds the shared phone when it has its own primary' do
    card = create(:contact, account: account, name: 'Relative', phone_number: '+77000000002',
                            custom_attributes: { 'medelement_patient_code' => 'relative-2', 'secondary_phones' => [owner.phone_number] })
    expect(bind!(code: 'relative-2').id).to eq(card.id)
    expect(card.reload.phone_number).to eq('+77000000002')
    expect(Array(card.custom_attributes['secondary_phones'])).not_to include(owner.phone_number)
    expect(card.custom_attributes).not_to have_key(described_class::SHARED_OWNER_KEY)
    expect(patient_snapshot.dig('patient', 'payload')).to include('patient_phone_2[0]' => '7', 'patient_phone_2[1]' => '700',
                                                                  'patient_phone_2[2]' => '0000002')
    expect(patient_snapshot['patient_phone_numbers']).to eq(['+77000000002'])
    expect(appointment).to have_attributes(contact_id: owner.id, client_phone: owner.phone_number, conversation_id: conversation.id)
  end

  it 'removes the recorded shared secondary when the separate card acquires its own primary' do
    card = bind!(code: 'relative-2')
    owner_attributes = owner.reload.attributes
    card.update!(phone_number: '+77000000002')

    expect(Array(card.reload.custom_attributes['secondary_phones'])).not_to include(owner.phone_number)
    expect(card.custom_attributes).not_to have_key(described_class::SHARED_OWNER_KEY)
    expect(card.custom_attributes).not_to have_key(described_class::SHARED_PHONE_KEY)
    expect(owner.reload.attributes).to eq(owner_attributes)
    expect(appointment.reload).to have_attributes(contact_id: owner.id, conversation_id: conversation.id, client_phone: owner.phone_number)
    expect(patient_snapshot['patient_phone_numbers']).to eq(['+77000000002'])
  end

  it 'removes the original shared secondary even after the communication owner changes primary' do
    card = bind!(code: 'relative-2')
    shared_phone = owner.phone_number
    owner.update!(phone_number: '+77000000004')
    card.update!(phone_number: '+77000000002')

    expect(Array(card.reload.custom_attributes['secondary_phones'])).not_to include(shared_phone)
    expect(card.custom_attributes).not_to have_key(described_class::SHARED_OWNER_KEY)
    expect(owner.reload.phone_number).to eq('+77000000004')
  end

  it 'normalizes the bound patient primary instead of falling back to the communication phone' do
    card = bind!(code: 'relative-2')
    allow(card).to receive(:phone_number).and_return('8 (700) 000-00-02')
    appointment.patient_contact = card

    expect(patient_snapshot['patient_phone_numbers']).to eq(['+77000000002'])
    expect(patient_snapshot.dig('patient', 'payload')).to include('patient_phone_2[0]' => '7', 'patient_phone_2[1]' => '700',
                                                                  'patient_phone_2[2]' => '0000002')
  end

  it 'rejects a foreign native card before using any of its patient phones' do
    appointment.patient_contact = create(:contact, phone_number: '+77000000002')
    expect { patient_snapshot }.to raise_error(Scheduling::Error) do |error|
      expect(error.code).to eq('MEDELEMENT_PATIENT_IDENTITY_CONFLICT')
    end
  end

  it 'rejects an invalid bound patient primary rather than silently using the shared phone' do
    card = bind!(code: 'relative-2')
    allow(card).to receive(:phone_number).and_return('+12025550123')
    appointment.patient_contact = card
    expect { patient_snapshot }.to raise_error(Scheduling::Error) do |error|
      expect(error.code).to eq('MEDELEMENT_PATIENT_PHONE_INVALID')
    end
  end

  it 'keeps a completed reception receipt current after normal patient primary sync and clearing' do
    card = bind!(code: 'relative-2')
    provider_command = command(snapshot: patient_snapshot(operation: 'create_reception'), status: 'succeeded', code: 'relative-2')
    card.update!(phone_number: '+77000000002')
    expect(policy.current?(provider_command.reload)).to be(true)
    card.update!(phone_number: nil)
    expect(policy.current?(provider_command.reload)).to be(true)
    expect(appointment.reload).to have_attributes(contact_id: owner.id, conversation_id: conversation.id, client_phone: owner.phone_number)
  end

  it 'blocks a late patient callback when the captured native card acquires its own primary' do
    card = bind!(code: 'relative-2')
    provider_command = command(snapshot: patient_snapshot, code: 'relative-2', operation: 'update_patient')
    card.update!(phone_number: '+77000000002')

    expect do
      Integrations::Medelement::ProviderCommands::SuccessApplier.new(command: provider_command).patient!(patient_code: 'relative-2')
    end.to raise_error(Scheduling::Error) { |error| expect(error.code).to eq('MEDELEMENT_RECEPTION_COMMAND_STALE_LOCAL') }
    expect(provider_command.reload.status).to eq('processing')
    expect(provider_command.request_snapshot['patient_phone_numbers']).to eq([owner.phone_number])
    expect(owner.reload.custom_attributes['medelement_patient_code']).to eq('primary-1')
  end

  it 'uses a private available primary phone for the separate card' do
    appointment.update!(client_phone: '+77000000003')
    card = bind!
    expect(card.phone_number).to eq('+77000000003')
    expect(card.custom_attributes).not_to have_key(described_class::SHARED_OWNER_KEY)
  end

  it 'rejects a code that belongs to the communication owner instead of merging the patients' do
    expect { bind!(code: 'primary-1') }.to raise_error(Scheduling::Error) { |error| expect(error.code).to eq('MEDELEMENT_PATIENT_IDENTITY_CONFLICT') }
    expect(appointment.reload.patient_contact_id).to be_nil
    expect(owner.reload.custom_attributes['medelement_patient_code']).to eq('primary-1')
  end

  it 'refuses a provider callback code that differs from the recorded appointment reference before any write' do
    appointment.update!(client_identifier: '940720300129',
                        custom_attributes: appointment.custom_attributes.merge('medelement_patient_code' => 'relative-2'))
    other = create(:contact, account: account, name: 'Other', custom_attributes: { 'medelement_patient_code' => 'other-3' })

    expect { bind!(code: 'other-3') }.to raise_error(Scheduling::Error) { |error| expect(error.code).to eq('MEDELEMENT_PATIENT_IDENTITY_CONFLICT') }
    expect(appointment.reload).to have_attributes(patient_contact_id: nil)
    expect(appointment.custom_attributes['medelement_patient_code']).to eq('relative-2')
    expect(other.reload.custom_attributes).not_to include('iin', described_class::CARD_KEY)
  end

  it 'keeps a pre-release appointment unbound when the chat contact already holds its patient code' do
    owner.update!(custom_attributes: { 'medelement_patient_code' => 'relative-2' })
    appointment.update!(custom_attributes: appointment.custom_attributes.merge('medelement_patient_code' => 'relative-2'))
    owner_attributes = owner.reload.attributes

    expect(described_class.legacy_owner_holds_code?(appointment)).to be(true)
    expect(bind!(code: 'relative-2')).to be_nil
    expect(owner.reload.attributes).to eq(owner_attributes)
    expect(account.contacts.count).to eq(1)
  end

  it 'validates the patient card account' do
    foreign_card = create(:contact)
    appointment.patient_contact = foreign_card
    expect(appointment).not_to be_valid
    expect(appointment.errors[:patient_contact_id]).to be_present
  end

  it 'derives a shared delivery owner only from a server-bound card and its recorded secondary phone' do
    card = bind!
    expect(described_class.delivery_contact(card)).to eq(owner)
    card.update!(custom_attributes: card.custom_attributes.merge('secondary_phones' => []))
    expect(described_class.delivery_contact(card)).to eq(card)
  end

  it 'freezes the card ID and refuses a changed binding even when all patient fields remain equal' do
    bind!(code: 'relative-2')
    snapshot = { policy::SNAPSHOT_KEY => policy.current_snapshot(appointment), policy::BINDING_KEY => appointment.patient_contact_id }
    provider_command = command(snapshot: snapshot)
    expect(policy.current?(provider_command)).to be(true)
    appointment.update!(patient_contact: create(:contact, account: account, custom_attributes: { 'medelement_patient_code' => 'other-3' }))
    expect(policy.current?(provider_command.reload)).to be(false)
  end

  it 'rejects a concurrent provider reference change on the same native card before late application' do
    card = bind!(code: 'relative-2')
    snapshot = { policy::SNAPSHOT_KEY => policy.current_snapshot(appointment), policy::BINDING_KEY => card.id,
                 'provider_patient_code' => 'relative-2' }
    provider_command = command(snapshot: snapshot, code: 'relative-2')
    card.update!(custom_attributes: card.custom_attributes.merge('medelement_patient_code' => 'other-3'))

    expect(policy.current?(provider_command.reload)).to be(false)
    expect do
      Integrations::Medelement::ProviderCommands::SuccessApplier.new(command: provider_command).patient!(patient_code: 'relative-2')
    end.to raise_error(Scheduling::Error) { |error| expect(error.code).to eq('MEDELEMENT_RECEPTION_COMMAND_STALE_LOCAL') }
    expect(owner.reload.custom_attributes['medelement_patient_code']).to eq('primary-1')
  end

  it 'keeps an initially unknown reference current when it is resolved on the same frozen card' do
    card = bind!
    snapshot = { policy::SNAPSHOT_KEY => policy.current_snapshot(appointment), policy::BINDING_KEY => card.id }
    provider_command = command(snapshot: snapshot)
    bind!(code: 'relative-2')
    provider_command.update!(provider_patient_code: 'relative-2')

    expect(appointment.reload.patient_contact_id).to eq(card.id)
    expect(policy.current?(provider_command.reload)).to be(true)
  end

  it 'does not override a captured provider reference with a later changed command reference' do
    card = bind!(code: 'relative-2')
    snapshot = { policy::SNAPSHOT_KEY => policy.current_snapshot(appointment), policy::BINDING_KEY => card.id,
                 'provider_patient_code' => 'relative-2' }
    provider_command = command(snapshot: snapshot, code: 'relative-2')
    card.update!(custom_attributes: card.custom_attributes.merge('medelement_patient_code' => 'other-3'))
    appointment.update!(custom_attributes: appointment.custom_attributes.merge('medelement_patient_code' => 'other-3'))
    provider_command.update!(provider_patient_code: 'other-3')

    expect(policy.current?(provider_command.reload)).to be(false)
  end

  %w[processing failed reconciliation_required].each do |status|
    it "blocks binding adoption after an old #{status} published provider phase" do
      snapshot = { policy::SNAPSHOT_KEY => policy.current_snapshot(appointment), 'provider_patient_code' => 'relative-2' }
      command(snapshot: snapshot, status: status, code: 'relative-2')
      service = Scheduling::Appointments::UpsertService.new(account: account, appointment: appointment, params: { comment: 'Comment only' })
      expect { service.perform }.to raise_error(Scheduling::Error) { |error| expect(error.code).to eq('MEDELEMENT_BOOKING_REQUIRES_VERIFICATION') }
      expect(appointment.reload.patient_contact_id).to be_nil
      expect(account.contacts.where("custom_attributes ->> 'medelement_patient_code' = ?", 'relative-2')).to be_empty
    end
  end

  it 'allows a completed frozen command to adopt its own verified card and keeps the receipt current' do
    snapshot = { policy::SNAPSHOT_KEY => policy.current_snapshot(appointment), 'provider_patient_code' => 'relative-2' }
    provider_command = command(snapshot: snapshot, status: 'succeeded', code: 'relative-2')
    appointment.update!(custom_attributes: appointment.custom_attributes.merge('medelement_patient_code' => 'relative-2'))
    Scheduling::Appointments::UpsertService.new(account: account, appointment: appointment, params: { comment: 'Comment only' }).perform
    expect(appointment.reload.patient_contact.custom_attributes['medelement_patient_code']).to eq('relative-2')
    expect(policy.current?(provider_command.reload)).to be(true)
    provider_command.update!(status: 'processing')
    expect(policy.current?(provider_command.reload)).to be(false)
  end

  it 'does not accept a completed tuple-less command as proof for separate patient card adoption' do
    provider_command = command(snapshot: { 'provider_patient_code' => 'relative-2' }, status: 'succeeded', code: 'relative-2')
    bind!(code: 'relative-2')
    expect(policy.current?(provider_command.reload)).to be(false)
  end

  it 'captures the native binding and rejects a captured source from before card adoption' do
    bind!(code: 'relative-2')
    hook = build_stubbed(:integrations_hook, account: account, app_id: 'medelement', settings: { 'organization_id' => 'company-1' })
    attributes = { account: account, hook: hook, operation: 'update_patient', appointment: appointment, contact: owner }
    builder = Integrations::Medelement::ProviderCommands::RequestSnapshotBuilder
    snapshot = builder.new(**attributes).build
    expect(snapshot[policy::BINDING_KEY]).to eq(appointment.patient_contact_id)
    expect(snapshot['provider_patient_code']).to eq('relative-2')
    expect(snapshot.dig('patient', 'payload')).to include('name' => 'Relative', 'lastname' => 'Patient')
    expect { builder.new(**attributes, desired_attributes: { 'custom_attributes' => appointment.custom_attributes }).build }
      .to raise_error(Scheduling::Error) { |error| expect(error.code).to eq('MEDELEMENT_PATIENT_IDENTITY_CONFLICT') }
    expect(builder.new(**attributes, desired_attributes: { 'patient_contact_id' => appointment.patient_contact_id,
                                                           'custom_attributes' => appointment.custom_attributes }).build)
      .to include(policy::BINDING_KEY => appointment.patient_contact_id)
  end

  it 'reuses a confirmed same-name IIN card instead of assigning a duplicate identity to an unlinked placeholder' do
    placeholder = bind!
    known = create(:contact, account: account, name: 'Relative', last_name: 'Patient', identifier: '940720300129',
                             custom_attributes: { 'medelement_patient_code' => 'relative-2', 'iin' => '940720300129' })
    appointment.with_lock do
      appointment.client_identifier = known.identifier
      described_class.new(appointment: appointment).prepare!(allow_rebind: true)
      appointment.save!
    end
    expect(appointment.reload.patient_contact_id).to eq(known.id)
    expect(placeholder.reload.identifier).to be_nil
    expect(known.reload.custom_attributes['medelement_patient_code']).to eq('relative-2')
  end

  it 'refuses to silently replace a frozen placeholder during a provider callback' do
    bind!
    create(:contact, account: account, name: 'Relative', custom_attributes: { 'medelement_patient_code' => 'relative-2' })
    expect { bind!(code: 'relative-2') }.to raise_error(Scheduling::Error) do |error|
      expect(error.code).to eq('MEDELEMENT_PATIENT_IDENTITY_CONFLICT')
    end
    expect(appointment.reload.patient_contact.custom_attributes['medelement_patient_code']).to be_nil
  end

  [nil, '940720300119'].each do |identifier|
    it "preserves the old card while changing an unpublished authored IIN to #{identifier.inspect}" do
      appointment.update!(client_identifier: '940720300129')
      original = bind!
      snapshot = { policy::SNAPSHOT_KEY => policy.current_snapshot(appointment), policy::BINDING_KEY => original.id }
      provider_command = command(snapshot: snapshot, status: 'queued')
      provider_command.update!(execution_state: provider_command.execution_state.except('write_phase'))

      Scheduling::Appointments::UpsertService.new(account: account, appointment: appointment, params: { client_identifier: identifier }).perform

      expect(appointment.reload.patient_contact_id).not_to eq(original.id)
      expect(appointment.patient_contact.identifier).to eq(identifier)
      expect(original.reload.identifier).to eq('940720300129')
      expect(policy.current?(provider_command.reload)).to be(false)
    end
  end

  it 'reuses a compatible confirmed IIN card after correcting an unpublished draft IIN' do
    appointment.update!(client_identifier: '940720300129')
    original = bind!
    known = create(:contact, account: account, name: 'Relative', last_name: 'Patient', identifier: '940720300119',
                             custom_attributes: { 'medelement_patient_code' => 'relative-2', 'iin' => '940720300119' })

    Scheduling::Appointments::UpsertService.new(account: account, appointment: appointment,
                                                params: { client_identifier: known.identifier }).perform

    expect(appointment.reload.patient_contact_id).to eq(known.id)
    expect(original.reload.identifier).to eq('940720300129')
    expect(owner.reload.custom_attributes['medelement_patient_code']).to eq('primary-1')
  end

  it 'rolls back an authored IIN correction and native rebind after a provider phase is published' do
    appointment.update!(client_identifier: '940720300129')
    original = bind!
    snapshot = { policy::SNAPSHOT_KEY => policy.current_snapshot(appointment), policy::BINDING_KEY => original.id }
    provider_command = command(snapshot: snapshot)
    service = Scheduling::Appointments::UpsertService.new(account: account, appointment: appointment,
                                                          params: { client_identifier: '940720300119' })

    expect { service.perform }.to raise_error(Scheduling::Error) do |error|
      expect(error.code).to eq('MEDELEMENT_BOOKING_REQUIRES_VERIFICATION')
    end
    expect(appointment.reload).to have_attributes(patient_contact_id: original.id, client_identifier: original.identifier)
    expect(account.contacts.where(identifier: '940720300119')).to be_empty
    expect(policy.current?(provider_command.reload)).to be(true)
  end

  it 'rejects a valid IIN which belongs to another MedElement code without changing either card' do
    original = bind!(code: 'relative-2')
    other = create(:contact, account: account, name: 'Relative', last_name: 'Patient', identifier: '940720300129',
                             custom_attributes: { 'medelement_patient_code' => 'another-3', 'iin' => '940720300129' })
    appointment.with_lock do
      appointment.client_identifier = other.identifier
      expect { described_class.new(appointment: appointment).prepare!(allow_rebind: true) }.to raise_error(Scheduling::Error)
    end
    expect(original.reload.custom_attributes['medelement_patient_code']).to eq('relative-2')
    expect(other.reload.custom_attributes['medelement_patient_code']).to eq('another-3')
    expect(original.identifier).to be_nil
  end

  it 'rejects a binding change during provider lookup before any contact writeback or provider create' do
    appointment.update!(client_identifier: '940720300129')
    original = bind!
    hook = build_stubbed(:integrations_hook, account: account, app_id: 'medelement', settings: { 'organization_id' => 'company-1' })
    snapshot = Integrations::Medelement::ProviderCommands::RequestSnapshotBuilder.new(
      account: account, hook: hook, operation: 'create_patient', appointment: appointment, contact: owner
    ).build
    provider_command = command(snapshot: snapshot, operation: 'create_patient')
    replacement = create(:contact, account: account, name: 'Another', phone_number: nil)
    client = instance_double(Integrations::Medelement::Client)
    allow(client).to receive(:search_patients_by_iin) do
      appointment.update!(patient_contact: replacement)
      [{ 'PROFILE_CODE' => 'relative-2', 'NAME' => 'Relative', 'LASTNAME' => 'Patient',
         'IIN' => '940720300129', 'PATIENT_PHONE_2' => owner.phone_number }]
    end
    allow(client).to receive(:create_patient)
    resolver = Integrations::Medelement::ProviderCommands::PatientResolver.new(
      command: provider_command, client: client, organization_id: 'company-1', before_create: -> { raise 'Unexpected provider create' }
    )
    expect { resolver.resolve!(allow_create: true) }.to raise_error(Integrations::Medelement::ProviderCommands::ExecutionError)
    expect(client).not_to have_received(:create_patient)
    expect(replacement.reload.custom_attributes['medelement_patient_code']).to be_nil
    expect(original.reload.custom_attributes['medelement_patient_code']).to be_nil
    expect(owner.reload.custom_attributes['medelement_patient_code']).to eq('primary-1')
  end

  %w[processing succeeded].each do |status|
    it "keeps an old tuple-less #{status} target stale after native binding appears" do
      appointment.update!(custom_attributes: {})
      provider_command = command(snapshot: { 'version' => 2 }, status: status)
      expect(policy.current?(provider_command)).to be(true)
      appointment.update!(patient_contact: create(:contact, account: account, name: 'Relative'))
      expect(policy.current?(provider_command.reload)).to be(false)
    end
  end

  it 'blocks a late successful provider callback after the patient binding changes' do
    bind!(code: 'relative-2')
    snapshot = { policy::SNAPSHOT_KEY => policy.current_snapshot(appointment), policy::BINDING_KEY => appointment.patient_contact_id }
    provider_command = command(snapshot: snapshot)
    original_card = appointment.patient_contact
    appointment.update!(patient_contact: create(:contact, account: account))
    expect do
      Integrations::Medelement::ProviderCommands::SuccessApplier.new(command: provider_command).patient!(patient_code: 'relative-2')
    end.to raise_error(Scheduling::Error) { |error| expect(error.code).to eq('MEDELEMENT_RECEPTION_COMMAND_STALE_LOCAL') }
    expect(provider_command.reload.status).to eq('processing')
    expect(original_card.reload.custom_attributes['medelement_patient_code']).to eq('relative-2')
    expect(owner.reload.custom_attributes['medelement_patient_code']).to eq('primary-1')
  end

  # Owner decision 2026-09-30: with the shipped switches (all off) the provider write-back never makes the card's доп. номер
  # its primary, also after the holder released the number (promotion goes only through SharedPhonePromotionService).
  describe 'provider write-back after the holder released the family number' do
    let!(:family_phone) { owner.phone_number }

    def expect_family_number_kept(card)
      expect(card.reload.phone_number).to be_nil
      expect(card.custom_attributes['medelement_patient_code']).to eq('relative-2')
      expect(Contacts::SharedPhone.share_of(card)).to have_attributes(phone: family_phone, owner_id: owner.id)
      expect(account.contacts.where(phone_number: family_phone)).to be_empty
    end

    it 'keeps the доп. номер when the patient callback links the provider reference', :aggregate_failures do
      expect(Contacts::SharedPhoneSwitches.states.values).to all(be(false))
      card = bind!
      provider_command = command(snapshot: { policy::SNAPSHOT_KEY => policy.current_snapshot(appointment), policy::BINDING_KEY => card.id })
      owner.update!(phone_number: '+77000000004')

      Integrations::Medelement::ProviderCommands::SuccessApplier.new(command: provider_command).patient!(patient_code: 'relative-2')

      expect(provider_command.reload.provider_patient_code).to eq('relative-2')
      expect_family_number_kept(card)
    end

    it 'keeps the доп. номер when the provider patient lookup links the card', :aggregate_failures do
      expect(Contacts::SharedPhoneSwitches.states.values).to all(be(false))
      appointment.update!(client_identifier: '940720300129')
      card = bind!
      provider_command = command(snapshot: patient_snapshot(operation: 'create_patient'), operation: 'create_patient')
      owner.update!(phone_number: '+77000000004')
      client = instance_double(Integrations::Medelement::Client)
      allow(client).to receive(:search_patients_by_iin).and_return(
        [{ 'PROFILE_CODE' => 'relative-2', 'NAME' => 'Relative', 'LASTNAME' => 'Patient', 'IIN' => '940720300129',
           'PATIENT_PHONE_2' => family_phone, 'COMPANY_CODE' => 'company-1' }]
      )
      resolver = Integrations::Medelement::ProviderCommands::PatientResolver.new(
        command: provider_command, client: client, organization_id: 'company-1'
      )

      expect(resolver.resolve!(allow_create: false)).to eq('relative-2')
      expect_family_number_kept(card)
    end
  end
end
