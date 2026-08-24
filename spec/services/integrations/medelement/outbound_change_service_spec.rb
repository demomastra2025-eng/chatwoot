require 'rails_helper'

RSpec.describe Integrations::Medelement::OutboundChangeService do
  include ActiveJob::TestHelper

  let(:account) { create(:account).tap { |record| record.enable_features!('scheduling') } }
  let(:hook_settings) { attributes_for(:integrations_hook, :medelement)[:settings].merge('write_enabled' => true) }
  let!(:hook) { create(:integrations_hook, :medelement, account: account, settings: hook_settings) }
  let(:actor) { create(:user) }
  let(:account_user) { create(:account_user, account: account, user: actor) }
  let(:contact) do
    create(
      :contact,
      account: account,
      phone_number: '+77010000001',
      custom_attributes: { 'medelement_patient_code' => 'patient-1' }
    )
  end
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
  let(:appointment) do
    create(
      :scheduling_appointment,
      account: account,
      contact: contact,
      resource: resource,
      source: 'manual',
      custom_attributes: { 'medelement_cabinet_code' => 'cabinet-1' }
    )
  end

  before do
    clear_enqueued_jobs
    account_user
    schedule_service = instance_double(Integrations::Medelement::CronScheduleService, sync!: true)
    allow(Integrations::Medelement::CronScheduleService).to receive(:new).and_return(schedule_service)
  end

  it 'creates and system-confirms a reception command immediately for a local appointment' do
    command = described_class.new(
      entity_type: 'appointment',
      entity_id: appointment.id,
      event_name: 'appointment_created',
      actor_id: actor.id
    ).perform

    expect(command).to have_attributes(operation: 'create_reception', appointment_id: appointment.id)
    expect(command.request_snapshot.dig('reception', 'resource_id')).to eq(appointment.resource_id)
    expect(command.confirmation_request).to have_attributes(status: 'confirmed', resolution_source: 'system')
    expect(command.confirmation_request.resolution_metadata).to include('medelement_auto_sync' => true)
    expect(Integrations::Medelement::ProviderCommandConfirmationJob).to have_been_enqueued.with(command.confirmation_request_id)
  end

  it 'creates and system-confirms a Captain reception command without a user requester' do
    command = described_class.new(
      entity_type: 'appointment',
      entity_id: appointment.id,
      event_name: 'appointment_created',
      actor_id: nil
    ).perform

    expect(command).to have_attributes(
      operation: 'create_reception',
      appointment_id: appointment.id,
      requested_by_id: nil
    )
    expect(command.confirmation_request).to have_attributes(status: 'confirmed', requested_by_id: nil, resolution_source: 'system')
    expect(Integrations::Medelement::ProviderCommandConfirmationJob).to have_been_enqueued.with(command.confirmation_request_id)
  end

  it 'accepts new producer metadata through the legacy worker service call' do
    command = described_class.new(
      entity_type: 'appointment',
      entity_id: appointment.id,
      event_name: 'appointment_created',
      change: {
        account_id: account.id,
        payload_version: Integrations::Medelement::OutboundChangeJob::PAYLOAD_VERSION
      },
      actor_id: nil
    ).perform

    expect(command).to have_attributes(operation: 'create_reception', appointment_id: appointment.id, requested_by_id: nil)
  end

  it 'rejects an appointment that does not belong to the bound account' do
    foreign_account = create(:account)

    expect do
      described_class.new(
        entity_type: 'appointment',
        entity_id: appointment.id,
        account_id: foreign_account.id,
        event_name: 'appointment_created',
        actor_id: actor.id
      ).perform
    end.to raise_error(ActiveRecord::RecordNotFound)
  end

  it 'system-confirms an existing matching dashboard command instead of creating a duplicate' do
    existing = Integrations::Medelement::ProviderCommands::CreateService.new(
      account: account,
      hook: hook,
      appointment: appointment,
      operation: 'create_reception',
      idempotency_key: 'dashboard-command',
      company_cabinet_code: 'cabinet-1',
      actor: actor,
      desired_starts_at: appointment.starts_at,
      desired_ends_at: appointment.ends_at
    ).perform

    command = described_class.new(
      entity_type: 'appointment',
      entity_id: appointment.id,
      event_name: 'appointment_created',
      actor_id: actor.id
    ).perform

    expect(command.id).to eq(existing.id)
    expect(command.confirmation_request.reload).to be_confirmed
    expect(Integrations::Medelement::ProviderCommand.where(appointment: appointment).count).to eq(1)
  end

  it 'queues an immediate patient update only for a linked contact change' do
    command = described_class.new(
      entity_type: 'contact',
      entity_id: contact.id,
      event_name: 'contact_updated',
      change: { changed_attributes: { 'name' => %w[Before After] } }
    ).perform

    expect(command).to have_attributes(operation: 'update_patient', contact_id: contact.id)
    expect(command.confirmation_request).to have_attributes(status: 'confirmed', resolution_source: 'system')
  end

  it 'queues and system-confirms a patient creation for an actor-backed patient event' do
    contact.update!(
      name: 'Ivan',
      last_name: 'Ivanov',
      middle_name: 'Ivanovich',
      custom_attributes: {}
    )

    command = described_class.new(
      entity_type: 'contact',
      entity_id: contact.id,
      event_name: 'contact.created',
      actor_id: actor.id,
      change: { desired_attributes: contact.attributes.slice(*described_class::CONTACT_UPDATE_KEYS) }
    ).perform

    expect(command).to have_attributes(operation: 'create_patient', contact_id: contact.id, requested_by_id: actor.id)
    expect(command.confirmation_request).to have_attributes(status: 'confirmed', resolution_source: 'system')
  end

  it 'freezes the desired patient fields instead of reading a later contact value' do
    contact.update!(name: 'Later', last_name: 'Patient', email: 'later@example.com')

    command = described_class.new(
      entity_type: 'contact',
      entity_id: contact.id,
      event_name: 'contact.updated',
      actor_id: actor.id,
      change: {
        changed_attributes: { 'name' => %w[Before After], 'email' => %w[before@example.com after@example.com] },
        desired_attributes: { 'name' => 'After', 'email' => 'after@example.com' }
      }
    ).perform

    expect(command.request_snapshot.dig('patient', 'payload')).to include(
      'name' => 'After',
      'patient_email' => 'after@example.com'
    )
  end

  it 'reuses the stable source-event idempotency key after the contact changes again' do
    desired = contact.attributes.slice(*described_class::CONTACT_UPDATE_KEYS)
    attributes = {
      entity_type: 'contact',
      entity_id: contact.id,
      event_name: 'contact.updated',
      event_key: 'onelink-event:stable-contact-event',
      actor_id: actor.id,
      change: {
        changed_attributes: { 'name' => %w[Before Event] },
        desired_attributes: desired.merge('name' => 'Event', 'last_name' => 'Patient')
      }
    }
    first = described_class.new(**attributes).perform
    contact.update!(
      name: 'Later',
      phone_number: ['+7', '702', '123', '4567'].join,
      custom_attributes: contact.custom_attributes.merge('medelement_patient_code' => 'patient-2')
    )

    second = described_class.new(**attributes).perform

    expect(second.id).to eq(first.id)
    expect(second.request_snapshot.dig('patient', 'payload', 'name')).to eq('Event')
    expect(Integrations::Medelement::ProviderCommand.where(contact: contact).count).to eq(1)
  end

  it 'builds a reception from the frozen appointment event instead of later records' do
    appointment.update!(client_phone: ['+7', '701', '123', '4567'].join)
    desired = appointment.attributes.slice(*described_class::APPOINTMENT_SNAPSHOT_KEYS).merge(
      described_class::CONTACT_SNAPSHOT_KEY => contact.attributes.slice(*described_class::CONTACT_UPDATE_KEYS).merge('custom_attributes' => {}),
      described_class::SPECIALIST_CODE_KEY => 'specialist-1',
      described_class::SPECIALIST_NAME_KEY => resource.name,
      described_class::NOMENCLATURE_CODES_KEY => [],
      described_class::SERVICE_NAME_KEY => appointment.service_name_snapshot
    )
    event_starts_at = appointment.starts_at
    event_phone = appointment.client_phone
    appointment.update!(
      starts_at: appointment.starts_at + 2.hours,
      ends_at: appointment.ends_at + 2.hours,
      client_phone: ['+7', '702', '123', '4567'].join
    )
    contact.update!(phone_number: ['+7', '703', '123', '4567'].join)
    resource.update!(custom_attributes: resource.custom_attributes.merge('medelement_specialist_code' => 'specialist-2'))

    command = described_class.new(
      entity_type: 'appointment',
      entity_id: appointment.id,
      event_name: 'appointment_created',
      event_key: 'onelink-event:stable-appointment-event',
      actor_id: actor.id,
      change: { desired_attributes: desired }
    ).perform

    expect(command.request_snapshot.dig('reception', 'destination_starts_at')).to eq(event_starts_at.utc.iso8601(6))
    expect(command.request_snapshot.dig('patient', 'phone_number')).to eq(event_phone)
    expect(command.request_snapshot.dig('reception', 'specialist_code')).to eq('specialist-1')
  end

  it 'does not create a provider command for an unlinked contact' do
    contact.update!(custom_attributes: {})

    expect(
      described_class.new(
        entity_type: 'contact',
        entity_id: contact.id,
        event_name: 'contact_updated',
        change: { changed_attributes: { 'name' => %w[Before After] } }
      ).perform
    ).to be_nil
    expect(Integrations::Medelement::ProviderCommand.where(contact: contact)).to be_empty
  end

  it 'does not reuse an unfinished reception command for a newer desired time' do
    existing = Integrations::Medelement::ProviderCommands::CreateService.new(
      account: account,
      hook: hook,
      appointment: appointment,
      operation: 'create_reception',
      idempotency_key: 'first-create-intent',
      company_cabinet_code: 'cabinet-1',
      actor: actor,
      desired_starts_at: appointment.starts_at,
      desired_ends_at: appointment.ends_at
    ).perform
    desired_starts_at = appointment.starts_at + 1.hour
    desired_ends_at = appointment.ends_at + 1.hour

    expect do
      described_class.new(
        entity_type: 'appointment',
        entity_id: appointment.id,
        event_name: 'appointment.updated',
        actor_id: actor.id,
        change: {
          changed_attributes: {
            'starts_at' => [appointment.starts_at, desired_starts_at],
            'ends_at' => [appointment.ends_at, desired_ends_at]
          },
          desired_attributes: { 'starts_at' => desired_starts_at, 'ends_at' => desired_ends_at }
        }
      ).perform
    end.to raise_error(Scheduling::Error) { |error| expect(error.code).to eq('MEDELEMENT_COMMAND_IN_PROGRESS') }

    expect(existing.reload).to be_awaiting_confirmation
    expect(Integrations::Medelement::ProviderCommand.where(appointment: appointment).count).to eq(1)
  end

  it 'does not reuse an unfinished reception command for a different immutable event snapshot' do
    first_attributes = {
      entity_type: 'appointment',
      entity_id: appointment.id,
      event_name: 'appointment_created',
      event_key: 'onelink-event:first-create',
      actor_id: actor.id,
      change: { desired_attributes: described_class.appointment_event_snapshot(appointment) }
    }
    first = described_class.new(**first_attributes).perform
    second_snapshot = first_attributes.dig(:change, :desired_attributes).merge(
      'client_phone' => ['+7', '702', '123', '4567'].join
    )

    expect do
      described_class.new(
        **first_attributes,
        event_key: 'onelink-event:second-create',
        change: { desired_attributes: second_snapshot }
      ).perform
    end.to raise_error(Scheduling::Error) { |error| expect(error.code).to eq('MEDELEMENT_COMMAND_IN_PROGRESS') }

    expect(first.reload).to be_awaiting_confirmation
    expect(Integrations::Medelement::ProviderCommand.where(appointment: appointment).count).to eq(1)
  end

  it 'freezes the pre-update provider time in an immediate move command' do
    source_starts_at = appointment.starts_at
    source_ends_at = appointment.ends_at
    destination_starts_at = source_starts_at + 1.hour
    destination_ends_at = source_ends_at + 1.hour
    appointment.update!(
      starts_at: destination_starts_at,
      ends_at: destination_ends_at,
      external_ref: 'medelement:reception:reception-1',
      custom_attributes: appointment.custom_attributes.merge('medelement_reception_code' => 'reception-1')
    )

    command = described_class.new(
      entity_type: 'appointment',
      entity_id: appointment.id,
      event_name: 'appointment.updated',
      actor_id: actor.id,
      change: {
        changed_attributes: {
          'starts_at' => [source_starts_at, destination_starts_at],
          'ends_at' => [source_ends_at, destination_ends_at]
        },
        desired_attributes: { 'starts_at' => destination_starts_at, 'ends_at' => destination_ends_at }
      }
    ).perform

    expect(command.request_snapshot.fetch('reception')).to include(
      'source_starts_at' => source_starts_at.utc.iso8601(6),
      'source_ends_at' => source_ends_at.utc.iso8601(6),
      'destination_starts_at' => destination_starts_at.utc.iso8601(6),
      'destination_ends_at' => destination_ends_at.utc.iso8601(6)
    )
  end

  it 'creates an immediate removal command for a locally cancelled provider reception' do
    appointment.update!(
      source: 'medelement',
      external_ref: 'medelement:reception:reception-1',
      custom_attributes: appointment.custom_attributes.merge('medelement_reception_code' => 'reception-1'),
      status: 'cancelled',
      payment_status: 'cancelled'
    )

    command = described_class.new(
      entity_type: 'appointment',
      entity_id: appointment.id,
      event_name: 'appointment_cancelled',
      change: {
        changed_attributes: { 'status' => %w[scheduled cancelled] },
        desired_attributes: { 'status' => 'cancelled' }
      },
      actor_id: actor.id
    ).perform

    expect(command).to have_attributes(operation: 'remove_reception', provider_reception_code: 'reception-1')
    expect(command.confirmation_request).to be_confirmed
  end

  it 'does not duplicate a removal through the generic appointment updated event' do
    appointment.update!(
      external_ref: 'medelement:reception:reception-1',
      custom_attributes: appointment.custom_attributes.merge('medelement_reception_code' => 'reception-1'),
      status: 'cancelled'
    )

    result = described_class.new(
      entity_type: 'appointment',
      entity_id: appointment.id,
      event_name: 'appointment_updated',
      event_key: 'onelink-event:generic-cancel-update',
      change: {
        changed_attributes: { 'status' => %w[scheduled cancelled] },
        desired_attributes: described_class.appointment_event_snapshot(appointment)
      },
      actor_id: actor.id
    ).perform

    expect(result).to be_nil
    expect(Integrations::Medelement::ProviderCommand.where(appointment: appointment)).to be_empty
  end
end
