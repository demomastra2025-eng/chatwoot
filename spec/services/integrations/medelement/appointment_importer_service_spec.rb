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

  it 'rejects an active provider row after local cancellation before a removal command exists' do
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

    appointment = Scheduling::Appointments::UpsertService.new(
      account: account,
      appointment: appointment,
      params: { status: 'cancelled' }
    ).perform

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
