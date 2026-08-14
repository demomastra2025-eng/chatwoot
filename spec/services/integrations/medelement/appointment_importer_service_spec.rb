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
    expect(conflict_tracker).to have_received(:record!).with(
      hash_including(
        conflict_type: 'local_payment_preserved',
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
end
