require 'rails_helper'

RSpec.describe Integrations::Medelement::AppointmentImporterService do
  let(:account) { create(:account) }
  let(:resource) { create(:scheduling_resource, account: account) }
  let(:service) { described_class.new(account: account) }
  let(:reception) do
    {
      'RECEPTION_CODE' => '975592971773905133',
      'PATIENT_CODE' => '550990851604984873',
      'ACTIVE' => 1
    }
  end
  let(:import_context) do
    {
      starts_at: Time.zone.parse('2026-03-21 09:00:00'),
      ends_at: Time.zone.parse('2026-03-21 09:20:00'),
      specialist_code: '27492901726817790'
    }
  end

  it 'imports the separate subject while retaining the shared communication owner and subsequent route' do
    owner = create(:contact, account: account, name: 'Primary', phone_number: '+77000000001')
    patient = create(:contact, account: account, name: 'Relative', last_name: 'Patient', phone_number: nil,
                               custom_attributes: { 'medelement_patient_code' => reception['PATIENT_CODE'],
                                                    'medelement_patient_card' => true,
                                                    'medelement_shared_phone_owner_contact_id' => owner.id,
                                                    'secondary_phones' => [owner.phone_number] })
    result = service.upsert!(resource: resource, contact: patient, reception: reception, import_context: import_context)
    expect(result).to have_attributes(contact_id: owner.id, patient_contact_id: patient.id,
                                      client_name: 'Relative Patient', client_phone: owner.phone_number)
    conversation = create(:conversation, account: account, contact: owner)
    result.update!(conversation: conversation)
    patient.update!(phone_number: '+77000000002')
    service.upsert!(resource: resource, contact: patient, reception: reception,
                    import_context: import_context.merge(starts_at: import_context[:starts_at] + 1.hour, ends_at: import_context[:ends_at] + 1.hour))
    expect(result.reload).to have_attributes(contact_id: owner.id, conversation_id: conversation.id, patient_contact_id: patient.id,
                                             client_name: 'Relative Patient', client_phone: '+77000000002')
    expect(owner.reload).to have_attributes(name: 'Primary', phone_number: '+77000000001')
  end

  describe 'provider-side patient change of a bound MedElement reception' do
    let(:policy) { Integrations::Medelement::AppointmentPatientIdentity }
    let(:run) { Integrations::Medelement::SyncRun.create!(account: account, trigger: 'manual', status: 'running') }
    let(:service) { described_class.new(account: account, conflict_tracker: Integrations::Medelement::ConflictTracker.new(sync_run: run)) }
    let(:owner) { create(:contact, account: account, name: 'Primary', phone_number: '+77000000001') }
    let(:conversation) { create(:conversation, account: account, contact: owner) }
    let(:moved) { import_context.merge(starts_at: import_context[:starts_at] + 1.hour, ends_at: import_context[:ends_at] + 1.hour) }
    let(:sibling) do
      create(:contact, account: account, name: 'Sibling', last_name: 'Patient', phone_number: '+77000000003',
                       custom_attributes: { 'medelement_patient_code' => 'sibling-3' })
    end
    let!(:card) { shared_phone_card('Relative', reception['PATIENT_CODE']) }
    let!(:appointment) do
      service.upsert!(resource: resource, contact: card, reception: reception, import_context: import_context).tap do |record|
        record.update!(conversation: conversation)
      end
    end

    def shared_phone_card(name, code)
      create(:contact, account: account, name: name, last_name: 'Patient', phone_number: nil,
                       custom_attributes: { 'medelement_patient_code' => code, 'medelement_patient_card' => true,
                                            'medelement_shared_phone_owner_contact_id' => owner.id,
                                            'secondary_phones' => [owner.phone_number] })
    end

    def reimport!(contact, patient_code, extra = {})
      service.upsert!(resource: resource, contact: contact, reception: reception.merge('PATIENT_CODE' => patient_code).merge(extra),
                      import_context: moved)
    end

    it 'follows the new provider patient and then applies the time move and the removal' do
      expect(appointment).to have_attributes(source: 'medelement', contact_id: owner.id, patient_contact_id: card.id)

      reimport!(sibling, 'sibling-3')

      expect(appointment.reload).to have_attributes(contact_id: sibling.id, patient_contact_id: nil, conversation_id: nil,
                                                    client_name: 'Sibling Patient', client_phone: sibling.phone_number,
                                                    starts_at: moved[:starts_at], status: 'scheduled')
      expect(appointment.custom_attributes).not_to include(policy::OWNED_IDENTITY_KEY, 'medelement_patient_code')
      expect(run.observed_conflicts.find_by(conflict_type: 'patient_changed_by_provider')).to have_attributes(
        status: 'open', entity_type: 'appointment',
        details: hash_including('appointment_id' => appointment.id, 'previous_patient_contact_id' => card.id,
                                'new_patient_contact_id' => sibling.id)
      )

      reimport!(sibling, 'sibling-3', 'REMOVED' => 1)

      expect(appointment.reload).to have_attributes(status: 'cancelled', contact_id: sibling.id, starts_at: moved[:starts_at])
      expect(card.reload.custom_attributes).to include('medelement_patient_code' => reception['PATIENT_CODE'])
      expect(owner.reload).to have_attributes(name: 'Primary', phone_number: '+77000000001')
    end

    it 'keeps the chat route and conversation when the new provider patient shares the number' do
      relative = shared_phone_card('Second', 'second-4')

      reimport!(relative, 'second-4')

      expect(appointment.reload).to have_attributes(contact_id: owner.id, conversation_id: conversation.id, patient_contact_id: relative.id,
                                                    client_name: 'Second Patient', client_phone: owner.phone_number,
                                                    starts_at: moved[:starts_at])
      expect(appointment.custom_attributes).to include(policy::OWNED_IDENTITY_KEY => true, 'medelement_patient_code' => 'second-4')

      reimport!(relative, 'second-4', 'REMOVED' => 1)

      expect(appointment.reload).to have_attributes(status: 'cancelled', patient_contact_id: relative.id, conversation_id: conversation.id)
      expect(run.observed_conflicts.where(conflict_type: 'patient_changed_by_provider').count).to eq(1)
    end

    it 'clears the patient card when MedElement moves the reception to the chat contact itself' do
      owner.update!(custom_attributes: { 'medelement_patient_code' => 'primary-1' })

      reimport!(owner, 'primary-1')

      expect(appointment.reload).to have_attributes(contact_id: owner.id, conversation_id: conversation.id, patient_contact_id: nil,
                                                    client_name: 'Primary', starts_at: moved[:starts_at])
      expect(appointment.custom_attributes).not_to include(policy::OWNED_IDENTITY_KEY, 'medelement_patient_code')
      expect(owner.reload.custom_attributes).to eq('medelement_patient_code' => 'primary-1')
    end

    it 'keeps the binding and the chat route when MedElement only re-codes the bound patient card' do
      card.update!(phone_number: '+77000000004', custom_attributes: card.custom_attributes.merge('medelement_patient_code' => 'recoded-5'))

      reimport!(card, 'recoded-5')

      expect(appointment.reload).to have_attributes(contact_id: owner.id, conversation_id: conversation.id, patient_contact_id: card.id,
                                                    starts_at: moved[:starts_at])
      expect(appointment.custom_attributes).to include(policy::OWNED_IDENTITY_KEY => true, 'medelement_patient_code' => 'recoded-5')
      expect(run.observed_conflicts.where(conflict_type: 'patient_changed_by_provider')).to be_empty
    end

    it 'keeps the captured binding only while a local provider write for the appointment is in flight' do
      in_flight = create_command(status: 'processing', write_phase: 'reception_move')

      expect { reimport!(sibling, 'sibling-3') }.to raise_error(Scheduling::Error) do |error|
        expect(error.code).to eq('MEDELEMENT_BOOKING_REQUIRES_VERIFICATION')
      end
      expect(appointment.reload).to have_attributes(contact_id: owner.id, patient_contact_id: card.id, starts_at: import_context[:starts_at])

      in_flight.update_columns(status: 'failed') # rubocop:disable Rails/SkipsModelValidations
      create_command(status: 'queued')
      reimport!(sibling, 'sibling-3')

      expect(appointment.reload).to have_attributes(contact_id: sibling.id, patient_contact_id: nil, starts_at: moved[:starts_at])
    end

    def create_command(status:, write_phase: nil)
      Integrations::Medelement::ProviderCommand.new(
        account: account, appointment: appointment, contact: owner, operation: 'move_reception', status: status,
        idempotency_key: SecureRandom.uuid, execution_state: { 'write_phase' => write_phase }.compact
      ).tap { |command| command.save!(validate: false) }
    end
  end

  describe 'owned appointments created before separate patient cards' do
    let(:policy) { Integrations::Medelement::AppointmentPatientIdentity }
    let(:account) { create(:account).tap { |record| record.enable_features!('scheduling') } }
    let(:resource) do
      create(:scheduling_resource, account: account,
                                   custom_attributes: { 'medelement_specialist_code' => 'specialist-1',
                                                        'medelement_cabinets' => [{ 'companyCabinetCode' => 'cabinet-1' }] })
    end
    let(:owner_code) { 'primary-1' }
    let(:owner) do
      create(:contact, account: account, name: 'Primary', phone_number: '+77000000001',
                       custom_attributes: { 'medelement_patient_code' => owner_code })
    end
    let(:appointment) do
      create(:scheduling_appointment, account: account, contact: owner, resource: resource, service: nil,
                                      client_first_name: 'Relative', client_last_name: 'Patient', client_middle_name: nil,
                                      client_name: 'Relative Patient', client_phone: owner.phone_number, client_identifier: '940720300129',
                                      custom_attributes: { policy::EXPLICIT_IDENTIFIER_KEY => true, policy::OWNED_IDENTITY_KEY => true,
                                                           'medelement_cabinet_code' => 'cabinet-1' }).tap do |record|
        record.update_columns(external_ref: 'medelement:reception:reception-2', # rubocop:disable Rails/SkipsModelValidations
                              custom_attributes: record.custom_attributes.merge('medelement_patient_code' => 'relative-2',
                                                                                'medelement_reception_code' => 'reception-2',
                                                                                'medelement_provider_sync_status' => 'succeeded'))
        record.reload
      end
    end
    let(:run) { Integrations::Medelement::SyncRun.create!(account: account, trigger: 'manual', status: 'running') }
    let(:service) { described_class.new(account: account, conflict_tracker: Integrations::Medelement::ConflictTracker.new(sync_run: run)) }

    before do
      Integrations::Medelement::ProviderCommand.create!(
        account: account, appointment: appointment, contact: owner, operation: 'create_reception', status: 'succeeded',
        company_cabinet_code: 'cabinet-1', provider_patient_code: 'relative-2', idempotency_key: SecureRandom.uuid,
        execution_state: { 'write_phase' => 'reception_create',
                           'request_snapshot' => { 'provider_patient_code' => 'relative-2',
                                                   policy::SNAPSHOT_KEY => policy.current_snapshot(appointment) } }
      )
    end

    def import!(patient_code, contact: nil)
      service.upsert!(
        resource: resource, contact: contact,
        reception: { 'RECEPTION_CODE' => 'reception-2', 'PATIENT_CODE' => patient_code, 'ACTIVE' => 1 },
        import_context: { starts_at: appointment.starts_at + 1.hour, ends_at: appointment.ends_at + 1.hour, specialist_code: 'specialist-1' }
      )
    end

    it 'rejects a reception that now carries another patient code before any card or contact write' do
      other = create(:contact, account: account, name: 'Other', phone_number: nil,
                               custom_attributes: { 'medelement_patient_code' => 'other-3' })
      contacts_before = account.contacts.count
      starts_at = appointment.starts_at

      [other, nil].each do |contact|
        expect { import!('other-3', contact: contact) }.to raise_error(Scheduling::Error) do |error|
          expect(error.code).to eq('MEDELEMENT_PATIENT_IDENTITY_CONFLICT')
        end
      end

      expect(appointment.reload).to have_attributes(patient_contact_id: nil, starts_at: starts_at)
      expect(appointment.custom_attributes['medelement_patient_code']).to eq('relative-2')
      expect(other.reload.custom_attributes).not_to include('iin', 'medelement_patient_card')
      expect(account.contacts.count).to eq(contacts_before)
    end

    # Owner decision 2026-09-30: with the shipped switches (all off) no entry point promotes a доп. номер.
    it 'never makes the card доп. номер its primary on a reimport after the holder released the number', :aggregate_failures do
      expect(Contacts::SharedPhoneSwitches.states.values).to all(be(false))
      import!('relative-2')
      card = appointment.reload.patient_contact
      expect(card.phone_number).to be_nil
      expect(Contacts::SharedPhone.share_of(card)).to have_attributes(phone: '+77000000001', owner_id: owner.id)

      owner.update!(phone_number: '+77000000004')
      import!('relative-2')

      expect(appointment.reload.patient_contact_id).to eq(card.id)
      expect(card.reload.phone_number).to be_nil
      expect(Contacts::SharedPhone.share_of(card)).to have_attributes(phone: '+77000000001', owner_id: owner.id)
      expect(account.contacts.where(phone_number: '+77000000001')).to be_empty
    end

    context 'when the chat contact already holds the appointment patient code' do
      let(:owner_code) { 'relative-2' }

      it 'keeps the unbound import behaviour and records a repair conflict instead of failing' do
        owner_attributes = owner.reload.attributes
        starts_at = appointment.starts_at

        import!('relative-2', contact: owner)

        expect(appointment.reload).to have_attributes(patient_contact_id: nil, contact_id: owner.id, starts_at: starts_at + 1.hour)
        expect(owner.reload.attributes.except('updated_at', 'last_activity_at')).to eq(owner_attributes.except('updated_at', 'last_activity_at'))
        expect(run.observed_conflicts.find_by(conflict_type: 'patient_card_repair_required')).to have_attributes(
          status: 'open', entity_type: 'appointment', details: hash_including('appointment_id' => appointment.id)
        )
      end

      it 'keeps comment-only edits available until the repair runs' do
        Scheduling::Appointments::UpsertService.new(account: account, appointment: appointment.reload,
                                                    params: { client_comment: 'Comment only' }).perform

        expect(appointment.reload).to have_attributes(client_comment: 'Comment only', patient_contact_id: nil)
        expect(owner.reload.custom_attributes['medelement_patient_code']).to eq('relative-2')
      end
    end
  end

  it 'uses a normalized secondary patient phone when the contact main phone is unavailable' do
    secondary_phone = ['+7', '700', '101', '3034'].join
    contact = create(
      :contact,
      account: account,
      phone_number: nil,
      custom_attributes: { 'secondary_phones' => ['', secondary_phone] }
    )

    appointment = service.upsert!(
      resource: resource,
      contact: contact,
      reception: reception,
      import_context: import_context
    )

    expect(appointment.client_phone).to eq(secondary_phone)
  end

  it 'does not use a conflicting secondary phone for the appointment' do
    conflicting_phone = ['+7', '701', '523', '5543'].join
    safe_secondary_phone = ['+7', '777', '111', '2233'].join
    contact = create(
      :contact,
      account: account,
      phone_number: nil,
      custom_attributes: {
        'phone_conflict_comment' => "Phone #{conflicting_phone} already belongs to another contact",
        'secondary_phones' => [conflicting_phone, safe_secondary_phone]
      }
    )

    appointment = service.upsert!(
      resource: resource,
      contact: contact,
      reception: reception,
      import_context: import_context
    )

    expect(appointment.client_phone).to eq(safe_secondary_phone)
  end

  it 'clears a linked conversation when a reimport resolves another contact' do
    original_contact = create(:contact, account: account)
    new_contact = create(:contact, account: account)
    conversation = create(:conversation, account: account, contact: original_contact)
    appointment = create(
      :scheduling_appointment,
      account: account,
      contact: original_contact,
      conversation: conversation,
      external_ref: service.external_ref_for(reception['RECEPTION_CODE']),
      resource: resource,
      source: 'medelement'
    )

    result = service.upsert!(
      resource: resource,
      contact: new_contact,
      reception: reception,
      import_context: import_context
    )

    expect(result.reload).to have_attributes(contact_id: new_contact.id, conversation_id: nil)
    expect(appointment.reload.conversation_id).to be_nil
  end

  it 'clears a linked conversation when a reimport no longer resolves a contact' do
    original_contact = create(:contact, account: account)
    conversation = create(:conversation, account: account, contact: original_contact)
    appointment = create(
      :scheduling_appointment,
      account: account,
      contact: original_contact,
      conversation: conversation,
      external_ref: service.external_ref_for(reception['RECEPTION_CODE']),
      resource: resource,
      source: 'medelement'
    )

    result = service.upsert!(
      resource: resource,
      contact: nil,
      reception: reception,
      import_context: import_context
    )

    expect(result.reload).to have_attributes(contact_id: nil, conversation_id: nil)
    expect(appointment.reload.conversation_id).to be_nil
  end

  it 'preserves a locally confirmed appointment while the provider reception remains active' do
    appointment = create(
      :scheduling_appointment,
      account: account,
      resource: resource,
      status: 'confirmed',
      source: 'medelement',
      external_ref: service.external_ref_for(reception['RECEPTION_CODE'])
    )

    service.upsert!(
      resource: resource,
      contact: nil,
      reception: reception,
      import_context: import_context
    )

    expect(appointment.reload.status).to eq('confirmed')
  end

  it 'completes a locally confirmed appointment when the provider reception becomes inactive' do
    appointment = create(
      :scheduling_appointment,
      account: account,
      resource: resource,
      status: 'confirmed',
      source: 'medelement',
      external_ref: service.external_ref_for(reception['RECEPTION_CODE'])
    )

    service.upsert!(
      resource: resource,
      contact: nil,
      reception: reception.merge('ACTIVE' => 0),
      import_context: import_context
    )

    expect(appointment.reload.status).to eq('completed')
  end

  {
    'неявка' => %w[no_show provider_explicit_no_show],
    'отменена' => %w[cancelled provider_explicit_cancelled],
    'завершена' => %w[completed provider_explicit_completed]
  }.each do |provider_status, (expected_status, expected_reason)|
    it "maps the explicit provider status #{provider_status} and records its source" do
      appointment = create(
        :scheduling_appointment,
        account: account,
        resource: resource,
        status: 'scheduled',
        source: 'medelement',
        external_ref: service.external_ref_for(reception['RECEPTION_CODE'])
      )

      service.upsert!(
        resource: resource,
        contact: nil,
        reception: reception.merge('VISIT_STATUS_NAME' => provider_status),
        import_context: import_context
      )

      expect(appointment.reload.status).to eq(expected_status)
      expect(appointment.custom_attributes['provider_status_audit']).to include(
        'source' => 'medelement_reception_sync',
        'previous_status' => 'scheduled',
        'status' => expected_status,
        'reason' => expected_reason,
        'raw_status' => provider_status
      )
    end
  end

  it 'reimports a trusted outbound appointment without changing its local origin' do
    contact = create(:contact, account: account)
    appointment = create(
      :scheduling_appointment,
      account: account,
      contact: contact,
      resource: resource,
      source: 'manual',
      external_ref: service.external_ref_for(reception['RECEPTION_CODE']),
      custom_attributes: {
        'medelement_reception_code' => reception['RECEPTION_CODE'],
        'medelement_provider_sync_status' => 'succeeded'
      }
    )
    Integrations::Medelement::ProviderCommand.create!(
      account: account,
      appointment: appointment,
      contact: contact,
      operation: 'create_reception',
      status: 'succeeded',
      idempotency_key: 'trusted-outbound-create',
      company_cabinet_code: 'cabinet-1',
      desired_starts_at: appointment.starts_at,
      desired_ends_at: appointment.ends_at
    )

    result = service.upsert!(
      resource: resource,
      contact: contact,
      reception: reception,
      import_context: import_context
    )

    expect(result.reload).to have_attributes(id: appointment.id, source: 'manual')
    expect(result.custom_attributes['source_mode']).to eq('outbound')
  end

  # rubocop:disable RSpec/ExampleLength
  it 'adopts a late provider reception into the original unknown outbound appointment' do
    account.enable_features!('scheduling')
    zone = ActiveSupport::TimeZone['Asia/Almaty']
    starts_at = zone.local(2026, 3, 21, 9, 0, 0)
    ends_at = zone.local(2026, 3, 21, 9, 20, 0)
    contact = create(
      :contact,
      account: account,
      phone_number: ['+7', '700', '000', '0001'].join,
      custom_attributes: { 'medelement_patient_code' => reception['PATIENT_CODE'] }
    )
    resource.update!(
      custom_attributes: {
        'medelement_specialist_code' => import_context[:specialist_code],
        'medelement_cabinets' => [{ 'companyCabinetCode' => 'cabinet-1' }]
      }
    )
    appointment = create(
      :scheduling_appointment,
      account: account,
      contact: contact,
      resource: resource,
      source: 'manual',
      starts_at: starts_at,
      ends_at: ends_at,
      custom_attributes: {
        'medelement_cabinet_code' => 'cabinet-1',
        'medelement_provider_sync_status' => 'provider_status_unknown'
      }
    )
    command = create_unknown_outbound_command(
      appointment: appointment,
      contact: contact,
      starts_at: starts_at,
      ends_at: ends_at
    )
    provider_reception = reception.merge(
      'SPECIALIST_CODE' => import_context[:specialist_code],
      'COMPANY_CABINET_CODE' => 'cabinet-1',
      'STARTTIME' => starts_at.in_time_zone(zone).strftime('%d.%m.%Y %H:%M:%S'),
      'ENDTIME' => ends_at.in_time_zone(zone).strftime('%d.%m.%Y %H:%M:%S'),
      'REMOVED' => 0,
      'SERVICES' => []
    )

    expect do
      result = service.upsert!(
        resource: resource,
        contact: nil,
        reception: provider_reception,
        import_context: import_context.merge(starts_at: starts_at, ends_at: ends_at)
      )

      expect(result.id).to eq(appointment.id)
    end.not_to change(account.scheduling_appointments, :count)

    expect(appointment.reload).to have_attributes(
      external_ref: service.external_ref_for(reception['RECEPTION_CODE']),
      source: 'manual',
      contact_id: contact.id
    )
    expect(appointment.custom_attributes).to include(
      'medelement_reception_code' => reception['RECEPTION_CODE'],
      'medelement_provider_sync_status' => 'succeeded',
      'source_mode' => 'outbound'
    )
    expect(command.reload).to have_attributes(
      status: 'succeeded',
      provider_reception_code: reception['RECEPTION_CODE']
    )
  end

  it 'requires manual resolution when the local appointment changed after the provider write' do
    account.enable_features!('scheduling')
    zone = ActiveSupport::TimeZone['Asia/Almaty']
    starts_at = zone.local(2026, 3, 21, 9, 0, 0)
    ends_at = zone.local(2026, 3, 21, 9, 20, 0)
    contact = create(
      :contact,
      account: account,
      phone_number: ['+7', '700', '000', '0003'].join,
      custom_attributes: { 'medelement_patient_code' => reception['PATIENT_CODE'] }
    )
    resource.update!(
      custom_attributes: {
        'medelement_specialist_code' => import_context[:specialist_code],
        'medelement_cabinets' => [{ 'companyCabinetCode' => 'cabinet-1' }]
      }
    )
    appointment = create(
      :scheduling_appointment,
      account: account,
      contact: contact,
      resource: resource,
      source: 'manual',
      starts_at: starts_at,
      ends_at: ends_at,
      custom_attributes: {
        'medelement_cabinet_code' => 'cabinet-1',
        'medelement_provider_sync_status' => 'provider_status_unknown'
      }
    )
    command = create_unknown_outbound_command(
      appointment: appointment,
      contact: contact,
      starts_at: starts_at,
      ends_at: ends_at
    )
    provider_reception = reception.merge(
      'SPECIALIST_CODE' => import_context[:specialist_code],
      'COMPANY_CABINET_CODE' => 'cabinet-1',
      'STARTTIME' => starts_at.in_time_zone(zone).strftime('%d.%m.%Y %H:%M:%S'),
      'ENDTIME' => ends_at.in_time_zone(zone).strftime('%d.%m.%Y %H:%M:%S'),
      'REMOVED' => 0,
      'SERVICES' => []
    )
    appointment.update!(starts_at: starts_at + 1.hour, ends_at: ends_at + 1.hour)

    expect do
      service.upsert!(
        resource: resource,
        contact: contact,
        reception: provider_reception,
        import_context: import_context.merge(starts_at: starts_at, ends_at: ends_at)
      )
    end.to raise_error(Scheduling::Error) { |error| expect(error.code).to eq('MEDELEMENT_RECEPTION_COMMAND_STALE_LOCAL') }

    expect(appointment.reload).to have_attributes(starts_at: starts_at + 1.hour, external_ref: nil)
    expect(command.reload).to be_provider_status_unknown
    expect(
      account.scheduling_appointments.where(external_ref: "medelement:reception:#{reception['RECEPTION_CODE']}")
    ).to be_empty
  end

  it 'does not create an imported appointment when a reception matches multiple unfinished commands' do
    account.enable_features!('scheduling')
    zone = ActiveSupport::TimeZone['Asia/Almaty']
    starts_at = zone.local(2026, 3, 21, 9, 0, 0)
    ends_at = zone.local(2026, 3, 21, 9, 20, 0)
    late_reception = reception.merge(
      'SPECIALIST_CODE' => '27492901726817790',
      'COMPANY_CABINET_CODE' => '5001',
      'STARTTIME' => starts_at.strftime('%d.%m.%Y %H:%M:%S'),
      'ENDTIME' => ends_at.strftime('%d.%m.%Y %H:%M:%S'),
      'REMOVED' => 0,
      'SERVICES' => []
    )
    contact = create(
      :contact,
      account: account,
      phone_number: ['+7', '700', '000', '0002'].join,
      custom_attributes: { 'medelement_patient_code' => reception['PATIENT_CODE'] }
    )
    resource.update!(
      custom_attributes: resource.custom_attributes.merge(
        'medelement_specialist_code' => late_reception['SPECIALIST_CODE'],
        'medelement_company_cabinet_code' => late_reception['COMPANY_CABINET_CODE']
      )
    )
    appointments = Array.new(2) do
      appointment = create(
        :scheduling_appointment,
        account: account,
        resource: resource,
        contact: contact,
        starts_at: starts_at,
        ends_at: ends_at,
        external_ref: nil
      )
      create_unknown_outbound_command(
        appointment: appointment,
        contact: contact,
        starts_at: starts_at,
        ends_at: ends_at,
        provider_reception: late_reception
      )
      appointment
    end

    expect do
      service.upsert!(
        resource: resource,
        contact: contact,
        reception: late_reception,
        import_context: {
          remote_updated_at: Time.zone.parse('2025-01-01 09:00:00'),
          source_version: 2,
          starts_at: starts_at,
          ends_at: ends_at,
          removed: false
        }
      )
    end.to raise_error(Scheduling::Error) { |error| expect(error.code).to eq('MEDELEMENT_RECEPTION_COMMAND_AMBIGUOUS') }
    expect(appointments.map { |appointment| appointment.reload.external_ref }).to all(be_nil)
    expect(
      account.scheduling_appointments.where(external_ref: "medelement:reception:#{late_reception['RECEPTION_CODE']}")
    ).to be_empty
  end
  # rubocop:enable RSpec/ExampleLength

  it 'rejects a provider snapshot captured before a newer local mutation' do
    mutation_at = Time.zone.parse('2026-03-20 10:00:01')
    appointment = create(
      :scheduling_appointment,
      account: account,
      resource: resource,
      source: 'medelement',
      status: 'cancelled',
      external_ref: service.external_ref_for(reception['RECEPTION_CODE'])
    )
    appointment.update!(updated_at: mutation_at)

    expect do
      service.upsert!(
        resource: resource,
        contact: appointment.contact,
        reception: reception,
        import_context: import_context.merge(snapshot_version: { exists: true, updated_at: mutation_at - 1.second })
      )
    end.to raise_error(Integrations::Medelement::AppointmentSnapshotGuard::StaleSnapshotError)

    expect(appointment.reload.status).to eq('cancelled')
  end

  it 'accepts a provider snapshot captured after the latest local mutation' do
    mutation_at = Time.zone.parse('2026-03-20 10:00:01')
    appointment = create(
      :scheduling_appointment,
      account: account,
      resource: resource,
      source: 'medelement',
      status: 'cancelled',
      external_ref: service.external_ref_for(reception['RECEPTION_CODE'])
    )
    appointment.update!(updated_at: mutation_at)

    service.upsert!(
      resource: resource,
      contact: appointment.contact,
      reception: reception,
      import_context: import_context.merge(snapshot_version: { exists: true, updated_at: mutation_at })
    )

    expect(appointment.reload.status).to eq('scheduled')
  end

  it 'rejects an active provider row after the matching removal was confirmed' do
    contact = create(:contact, account: account)
    appointment = create(
      :scheduling_appointment,
      account: account,
      contact: contact,
      resource: resource,
      source: 'manual',
      status: 'cancelled',
      external_ref: service.external_ref_for(reception['RECEPTION_CODE']),
      custom_attributes: { 'medelement_reception_code' => reception['RECEPTION_CODE'] }
    )
    Integrations::Medelement::ProviderCommand.create!(
      account: account,
      appointment: appointment,
      contact: contact,
      operation: 'remove_reception',
      status: 'succeeded',
      idempotency_key: 'confirmed-outbound-removal',
      provider_reception_code: reception['RECEPTION_CODE'],
      executed_at: Time.current
    )

    expect do
      service.upsert!(
        resource: resource,
        contact: contact,
        reception: reception,
        import_context: import_context.merge(
          snapshot_version: { exists: true, updated_at: appointment.updated_at }
        )
      )
    end.to raise_error(Integrations::Medelement::AppointmentSnapshotGuard::StaleSnapshotError)

    expect(appointment.reload.status).to eq('cancelled')
  end

  it 'rejects an active provider row for a historically cancelled appointment without a removal command' do
    removal_settings = attributes_for(:integrations_hook, :medelement)[:settings].merge('remove_reception_on_cancel' => true)
    account.enable_features!('scheduling')
    create(:integrations_hook, :medelement, account: account, settings: removal_settings)
    contact = create(:contact, account: account)
    appointment = create(
      :scheduling_appointment,
      account: account,
      contact: contact,
      resource: resource,
      source: 'manual',
      status: 'scheduled',
      external_ref: service.external_ref_for(reception['RECEPTION_CODE']),
      custom_attributes: { 'medelement_reception_code' => reception['RECEPTION_CODE'] }
    )
    allow(Rails.configuration.dispatcher).to receive(:dispatch)

    expect do
      Scheduling::Appointments::UpsertService.new(
        account: account, appointment: appointment, params: { status: 'cancelled' }
      ).perform
    end.to raise_error(Scheduling::Error) { |error| expect(error.code).to eq('MEDELEMENT_BOOKING_REQUIRES_VERIFICATION') }
    expect(appointment.reload.status).to eq('scheduled')
    appointment.update!(status: 'cancelled', custom_attributes: appointment.custom_attributes.merge(
      'medelement_local_cancelled_at' => Time.current.iso8601
    ))

    expect(appointment.custom_attributes['medelement_local_cancelled_at']).to be_present
    expect(Integrations::Medelement::ProviderCommand.where(appointment: appointment)).to be_empty
    expect do
      service.upsert!(
        resource: resource,
        contact: contact,
        reception: reception,
        import_context: import_context.merge(
          snapshot_version: { exists: true, updated_at: appointment.updated_at }
        )
      )
    end.to raise_error(Integrations::Medelement::AppointmentSnapshotGuard::StaleSnapshotError)

    expect(appointment.reload.status).to eq('cancelled')
  end

  it 'preserves a local-only service when the provider explicitly returns an empty SERVICES list' do
    local_service = create(
      :scheduling_service,
      account: account,
      custom_attributes: { 'medelement_nomenclature_code' => 'local-service' }
    )
    contact = create(:contact, account: account)
    appointment = create(
      :scheduling_appointment,
      account: account,
      contact: contact,
      resource: resource,
      service: local_service,
      service_name_snapshot: local_service.name,
      source: 'manual',
      external_ref: service.external_ref_for(reception['RECEPTION_CODE']),
      custom_attributes: {
        'medelement_reception_code' => reception['RECEPTION_CODE'],
        'medelement_provider_sync_status' => 'succeeded',
        'medelement_service_binding' => 'local_only',
        'medelement_local_nomenclature_codes' => ['local-service'],
        'medelement_provider_nomenclature_codes' => [],
        'service_ids' => [local_service.id],
        'services' => [{ 'id' => local_service.id, 'name' => local_service.name }]
      }
    )
    create_succeeded_outbound_command(appointment, contact)

    result = service.upsert!(
      resource: resource,
      contact: contact,
      reception: reception.merge('SERVICES' => []),
      import_context: import_context
    )

    expect(result.reload).to have_attributes(service_id: local_service.id, service_name_snapshot: local_service.name)
    expect(result.custom_attributes).to include(
      'medelement_service_binding' => 'local_only',
      'medelement_local_nomenclature_codes' => ['local-service'],
      'medelement_provider_nomenclature_codes' => [],
      'service_ids' => [local_service.id]
    )
  end

  it 'replaces a local-only service when the provider later returns an authoritative service' do
    local_service = create(
      :scheduling_service,
      account: account,
      custom_attributes: { 'medelement_nomenclature_code' => 'local-service' }
    )
    provider_service = create(
      :scheduling_service,
      account: account,
      custom_attributes: { 'medelement_nomenclature_code' => 'provider-service' }
    )
    contact = create(:contact, account: account)
    appointment = create(
      :scheduling_appointment,
      account: account,
      contact: contact,
      resource: resource,
      service: local_service,
      source: 'manual',
      external_ref: service.external_ref_for(reception['RECEPTION_CODE']),
      custom_attributes: {
        'medelement_reception_code' => reception['RECEPTION_CODE'],
        'medelement_provider_sync_status' => 'succeeded',
        'medelement_service_binding' => 'local_only',
        'medelement_local_nomenclature_codes' => ['local-service'],
        'service_ids' => [local_service.id]
      }
    )
    create_succeeded_outbound_command(appointment, contact)

    result = service.upsert!(
      resource: resource,
      contact: contact,
      reception: reception.merge('SERVICES' => [{ 'NOMENCLATURE_CODE' => 'provider-service' }]),
      import_context: import_context
    )

    expect(result.reload.service_id).to eq(provider_service.id)
    expect(result.custom_attributes).to include(
      'medelement_service_binding' => 'provider',
      'medelement_provider_nomenclature_codes' => ['provider-service'],
      'service_ids' => [provider_service.id]
    )
    expect(result.custom_attributes).not_to have_key('medelement_local_nomenclature_codes')
  end

  it 'rejects a manual appointment with an untrusted copied provider reference' do
    create(
      :scheduling_appointment,
      account: account,
      resource: resource,
      source: 'manual',
      external_ref: service.external_ref_for(reception['RECEPTION_CODE']),
      custom_attributes: { 'medelement_reception_code' => reception['RECEPTION_CODE'] }
    )

    expect do
      service.upsert!(
        resource: resource,
        contact: create(:contact, account: account),
        reception: reception,
        import_context: import_context
      )
    end.to raise_error(Scheduling::Error, 'external_ref is already used by a non-Medelement appointment')
  end

  it 'marks an unresolved patient without persisting the raw patient code as a client name' do
    appointment = service.upsert!(
      resource: resource,
      contact: nil,
      reception: reception,
      import_context: import_context
    )

    expect(appointment).to have_attributes(client_name: 'Unresolved MedElement patient', contact_id: nil)
    expect(appointment.client_name).not_to include(reception['PATIENT_CODE'])
    expect(appointment.custom_attributes['medelement_patient_unresolved']).to be(true)
  end

  it 'preserves local amounts and payments while recording provider conflicts' do
    contact = create(:contact, account: account)
    existing_service = create(:scheduling_service, account: account)
    create(
      :scheduling_appointment,
      account: account,
      contact: contact,
      resource: resource,
      source: 'medelement',
      external_ref: service.external_ref_for(reception['RECEPTION_CODE']),
      service: existing_service,
      service_amount: 3000,
      prepaid_amount: 1000,
      prepaid_payment_method: 'card',
      settlement_amount: 2000,
      settlement_payment_method: 'cash',
      payment_status: 'paid'
    )
    conflict_tracker = instance_double(Integrations::Medelement::ConflictTracker, record!: true)
    importer = described_class.new(account: account, conflict_tracker: conflict_tracker)
    provider_reception = reception.merge(
      'SERVICES' => [{ 'PRICE' => 5000, 'QUANTITY' => 1 }]
    )

    result = importer.upsert!(
      resource: resource,
      contact: contact,
      reception: provider_reception,
      import_context: import_context
    )

    expect(result.reload).to have_attributes(
      service_id: existing_service.id,
      service_amount: 3000,
      prepaid_amount: 1000,
      settlement_amount: 2000,
      payment_status: 'paid'
    )
    expect(conflict_tracker).to have_received(:record!).with(
      hash_including(
        conflict_type: 'appointment_amount_mismatch',
        entity_key: reception['RECEPTION_CODE'],
        details: hash_including(appointment_id: result.id, reception_code: reception['RECEPTION_CODE'])
      )
    )
  end

  it 'ignores soft-deleted provider service rows when resolving appointment services' do
    active_service = create(
      :scheduling_service,
      account: account,
      custom_attributes: { 'medelement_nomenclature_code' => 'active-service' }
    )
    deleted_service = create(
      :scheduling_service,
      account: account,
      custom_attributes: { 'medelement_nomenclature_code' => 'deleted-service' }
    )

    appointment = service.upsert!(
      resource: resource,
      contact: create(:contact, account: account),
      reception: reception.merge(
        'SERVICES' => [
          { 'NOMENCLATURE_CODE' => 'active-service', 'DELETED' => 0 },
          { 'NOMENCLATURE_CODE' => 'deleted-service', 'DELETED' => 1 }
        ]
      ),
      import_context: import_context
    )

    expect(appointment.reload.service_id).to eq(active_service.id)
    expect(appointment.custom_attributes['service_ids']).to eq([active_service.id])
    expect(appointment.custom_attributes['medelement_unresolved_service_codes']).to eq([])
    expect(deleted_service).to be_persisted
  end

  it 'clears stale service metadata when every provider service row is soft-deleted' do
    stale_service = create(
      :scheduling_service,
      account: account,
      custom_attributes: { 'medelement_nomenclature_code' => 'deleted-service' }
    )
    contact = create(:contact, account: account)
    create(
      :scheduling_appointment,
      account: account,
      contact: contact,
      resource: resource,
      service: stale_service,
      service_name_snapshot: stale_service.name,
      source: 'medelement',
      external_ref: service.external_ref_for(reception['RECEPTION_CODE']),
      custom_attributes: {
        'service_ids' => [stale_service.id],
        'services' => [{ 'id' => stale_service.id, 'name' => stale_service.name }]
      }
    )

    appointment = service.upsert!(
      resource: resource,
      contact: contact,
      reception: reception.merge(
        'SERVICES' => [{ 'NOMENCLATURE_CODE' => 'deleted-service', 'DELETED' => 1 }]
      ),
      import_context: import_context
    )

    expect(appointment.reload).to have_attributes(service_id: nil, service_name_snapshot: nil)
    expect(appointment.custom_attributes).to include(
      'service_ids' => [],
      'services' => [],
      'medelement_unresolved_service_codes' => []
    )
  end

  it 'does not mutate an existing appointment from a malformed services snapshot' do
    existing_service = create(:scheduling_service, account: account)
    contact = create(:contact, account: account)
    appointment = create(
      :scheduling_appointment,
      account: account,
      contact: contact,
      resource: resource,
      service: existing_service,
      service_name_snapshot: existing_service.name,
      service_amount: 4500,
      source: 'medelement',
      external_ref: service.external_ref_for(reception['RECEPTION_CODE']),
      custom_attributes: { 'service_ids' => [existing_service.id] }
    )

    [nil, [{}]].each do |malformed_services|
      expect do
        service.upsert!(
          resource: resource,
          contact: contact,
          reception: reception.merge('SERVICES' => malformed_services),
          import_context: import_context
        )
      end.to raise_error(Integrations::Medelement::ReceptionServiceRows::InvalidSnapshotError)
    end

    expect(appointment.reload).to have_attributes(
      service_id: existing_service.id,
      service_name_snapshot: existing_service.name,
      service_amount: 4500
    )
    expect(appointment.custom_attributes['service_ids']).to eq([existing_service.id])
  end

  def create_succeeded_outbound_command(appointment, contact)
    Integrations::Medelement::ProviderCommand.create!(
      account: account,
      appointment: appointment,
      contact: contact,
      operation: 'create_reception',
      status: 'succeeded',
      idempotency_key: SecureRandom.uuid,
      company_cabinet_code: 'cabinet-1',
      desired_starts_at: appointment.starts_at,
      desired_ends_at: appointment.ends_at
    )
  end

  # rubocop:disable Metrics/MethodLength
  def create_unknown_outbound_command(appointment:, contact:, starts_at:, ends_at:, provider_reception: reception)
    hook = account.hooks.find_by(app_id: 'medelement') || create(:integrations_hook, :medelement, account: account)
    snapshot = Integrations::Medelement::ProviderCommands::RequestSnapshotBuilder.new(
      account: account,
      hook: hook,
      appointment: appointment,
      contact: contact,
      operation: 'create_reception',
      company_cabinet_code: provider_reception['COMPANY_CABINET_CODE'] || 'cabinet-1',
      desired_starts_at: starts_at,
      desired_ends_at: ends_at
    ).build
    fingerprint = Integrations::Medelement::ProviderCommands::RequestSnapshotBuilder.fingerprint(snapshot)
    command = Integrations::Medelement::ProviderCommand.create!(
      account: account,
      hook: hook,
      appointment: appointment,
      contact: contact,
      operation: 'create_reception',
      status: 'provider_status_unknown',
      provider_patient_code: provider_reception['PATIENT_CODE'],
      idempotency_key: SecureRandom.uuid,
      company_cabinet_code: provider_reception['COMPANY_CABINET_CODE'] || 'cabinet-1',
      desired_starts_at: starts_at,
      desired_ends_at: ends_at,
      execution_state: {
        'write_phase' => 'reception_create',
        'write_provider_patient_code' => provider_reception['PATIENT_CODE'],
        'preflight_reception_codes' => [],
        'request_snapshot' => snapshot,
        'request_fingerprint' => fingerprint
      }
    )
    confirmation = create(
      :confirmation_request,
      account: account,
      contact: contact,
      status: 'confirmed',
      resolved_at: Time.current,
      metadata: {
        'medelement_provider_command_id' => command.id,
        'operation' => command.operation,
        'request_fingerprint' => fingerprint
      }
    )
    command.update!(
      confirmation_request: confirmation,
      execution_state: command.execution_state.merge('confirmation_request_id' => confirmation.id)
    )
    command
  end
  # rubocop:enable Metrics/MethodLength
end
