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
    expect(appointment.reload.custom_attributes['medelement_provider_sync_status']).to eq('pending')
  end

  it 'does not regress the provider status when execution finishes before status projection' do
    allow(Integrations::Medelement::ProviderCommandConfirmationJob).to receive(:perform_later) do |confirmation_request_id|
      completed_command = Integrations::Medelement::ProviderCommand.find_by!(
        confirmation_request_id: confirmation_request_id
      )
      completed_command.update!(status: completed_command.status_for_transition('succeeded'))
      Integrations::Medelement::AppointmentProviderStatus.persist!(
        completed_command.appointment,
        Integrations::Medelement::AppointmentProviderStatus::SUCCEEDED
      )
    end

    command = described_class.new(
      entity_type: 'appointment',
      entity_id: appointment.id,
      event_name: 'appointment_created',
      account_id: account.id,
      actor_id: actor.id,
      event_key: 'appointment:created:provider-race'
    ).perform

    expect(command.reload).to be_succeeded
    expect(appointment.reload.custom_attributes['medelement_provider_sync_status']).to eq('succeeded')
  end

  it 'binds a Captain booking before execution can acknowledge its create write' do
    assistant = create(:captain_assistant, account: account)
    conversation = create(:conversation, account: account, contact: contact)
    appointment.update!(conversation: conversation)
    provider_status = Integrations::Medelement::AppointmentProviderStatus

    allow(Integrations::Medelement::ProviderCommandConfirmationJob).to receive(:perform_later) do |request_id|
      dispatched = Integrations::Medelement::ProviderCommand.find_by!(confirmation_request_id: request_id)
      expect(provider_status.bound_to_command?(appointment.reload, dispatched)).to be(true)

      dispatched.update!(
        status: dispatched.status_for_transition('processing'),
        provider_patient_code: 'patient-1',
        execution_state: dispatched.execution_state.merge(
          'write_provider_reception_code' => 'early-reception', 'write_provider_patient_code' => 'patient-1'
        )
      )
      Integrations::Medelement::ProviderCommands::SuccessApplier.new(command: dispatched)
                                                                .reception_created!(reception_code: 'early-reception', patient_code: 'patient-1')
    end

    command = described_class.new(
      entity_type: 'appointment', entity_id: appointment.id, event_name: 'appointment_created',
      account_id: account.id, actor_descriptor: { type: 'Captain::Assistant', id: assistant.id },
      event_key: 'appointment:created:captain-early-success'
    ).perform

    expect(command.reload).to be_succeeded
    expect(appointment.reload.external_ref).to eq('medelement:reception:early-reception')
    appointment.medelement_provider_command_receipt = command
    expect(Captain::Tools::ProviderBookingOutcomeService.new(appointment: appointment, assistant: assistant).perform).to eq(command)
  end

  it 'exposes the projected command through the receipt when confirmation raises' do
    assistant = create(:captain_assistant, account: account)
    conversation = create(:conversation, account: account, contact: contact)
    appointment.update!(conversation: conversation)
    allow(Integrations::Medelement::ProviderCommands::AutoConfirmationService)
      .to receive(:new).and_raise(StandardError, 'Confirmation failed')
    receipt = Integrations::Medelement::AppointmentProviderCommandReceiptService.new(
      appointment: appointment, actor: assistant, new_record: true
    )

    expect { receipt.perform }.to raise_error(Scheduling::Error) { |error| expect(error.code).to eq('MEDELEMENT_COMMAND_RECEIPT_UNAVAILABLE') }
    expect(receipt.projected_command).to be_present
    expect(Integrations::Medelement::AppointmentProviderStatus.bound_to_command?(appointment.reload, receipt.projected_command)).to be(true)
    expect(appointment.custom_attributes[Integrations::Medelement::AppointmentProviderStatus::ATTRIBUTE_KEY]).to eq('pending')
  end

  it 'does not dispatch a Captain command if its booking changes before binding' do
    assistant = create(:captain_assistant, account: account)
    replacement = create(:scheduling_resource, account: account, custom_attributes: { 'medelement_specialist_code' => 'specialist-2' })
    service = described_class.new(
      entity_type: 'appointment', entity_id: appointment.id, event_name: 'appointment_created',
      account_id: account.id, actor_descriptor: { type: 'Captain::Assistant', id: assistant.id },
      event_key: 'appointment:created:captain-changed-before-binding'
    )
    allow(service).to receive(:create_appointment_command).and_wrap_original do |original, *args|
      command = original.call(*args)
      appointment.update!(resource: replacement)
      command
    end

    expect(Integrations::Medelement::ProviderCommandConfirmationJob).not_to receive(:perform_later)
    command = service.perform

    expect(command.reload).to be_cancelled
    expect(command.confirmation_request.reload).to be_expired
    expect(appointment.reload.resource_id).to eq(replacement.id)
    expect(appointment.custom_attributes[Integrations::Medelement::AppointmentProviderStatus::COMMAND_ID_KEY]).to be_nil
  end

  it 'allows the changed Captain booking to start after its unconfirmed old command is discarded' do
    assistant = create(:captain_assistant, account: account)
    replacement = create(
      :scheduling_resource,
      account: account,
      custom_attributes: {
        'medelement_specialist_code' => 'specialist-2',
        'medelement_cabinets' => [{ 'companyCabinetCode' => 'cabinet-1' }]
      }
    )
    first = described_class.new(
      entity_type: 'appointment', entity_id: appointment.id, event_name: 'appointment_created',
      account_id: account.id, actor_descriptor: { type: 'Captain::Assistant', id: assistant.id },
      event_key: 'appointment:created:captain-stale-first'
    )
    allow(first).to receive(:create_appointment_command).and_wrap_original do |original, *args|
      command = original.call(*args)
      appointment.update!(resource: replacement)
      command
    end

    stale = first.perform
    expect(stale.reload).to be_cancelled
    expect(stale.confirmation_request.reload).to be_expired

    current = described_class.new(
      entity_type: 'appointment', entity_id: appointment.id, event_name: 'appointment_created',
      account_id: account.id, actor_descriptor: { type: 'Captain::Assistant', id: assistant.id },
      event_key: 'appointment:created:captain-stale-second',
      change: { desired_attributes: described_class.appointment_event_snapshot(appointment) }
    ).perform

    expect(current.id).not_to eq(stale.id)
    expect(current.confirmation_request.reload).to be_confirmed
  end

  it 'retires a stale Captain patient-selection command before any provider write so the replacement can start' do
    assistant = create(:captain_assistant, account: account)
    first = described_class.new(
      entity_type: 'appointment', entity_id: appointment.id, event_name: 'appointment_created',
      account_id: account.id, actor_descriptor: { type: 'Captain::Assistant', id: assistant.id },
      event_key: 'appointment:created:patient-selection-first'
    ).perform
    first.update!(
      status: first.status_for_transition('awaiting_patient_selection'),
      execution_state: first.execution_state.merge('patient_action' => { 'type' => 'patient_selection' })
    )
    replacement = create(
      :scheduling_resource,
      account: account,
      custom_attributes: {
        'medelement_specialist_code' => 'specialist-2',
        'medelement_cabinets' => [{ 'companyCabinetCode' => 'cabinet-1' }]
      }
    )
    appointment.update!(resource: replacement)
    Integrations::Medelement::AppointmentProviderStatus.assign_pending!(appointment)
    appointment.save!

    current = described_class.new(
      entity_type: 'appointment', entity_id: appointment.id, event_name: 'appointment_updated',
      account_id: account.id, actor_descriptor: { type: 'Captain::Assistant', id: assistant.id },
      event_key: 'appointment:updated:patient-selection-second',
      change: { desired_attributes: described_class.appointment_event_snapshot(appointment) }
    ).perform

    expect(first.reload).to be_cancelled
    expect(current.id).not_to eq(first.id)
    expect(current.confirmation_request.reload).to be_confirmed
    client = instance_double(Integrations::Medelement::Client)
    expect(client).not_to receive(:create_reception)
    expect(Integrations::Medelement::ProviderCommands::Executor.new(command: first, client: client).perform).to be_nil
    expect do
      Integrations::Medelement::ProviderCommands::PatientActionsService.new(command: first, actor: actor).confirm_creation!
    end.to raise_error(Scheduling::Error) { |error| expect(error.code).to eq('patient_action_not_available') }
  end

  it 'does not retire a stale Captain patient-action command once any provider write may have started' do
    assistant = create(:captain_assistant, account: account)
    first = described_class.new(
      entity_type: 'appointment', entity_id: appointment.id, event_name: 'appointment_created',
      account_id: account.id, actor_descriptor: { type: 'Captain::Assistant', id: assistant.id },
      event_key: 'appointment:created:patient-write-first'
    ).perform
    first.update!(
      status: first.status_for_transition('awaiting_phone_refresh'),
      execution_state: first.execution_state.merge('write_phase' => 'patient_create')
    )
    replacement = create(:scheduling_resource, account: account, custom_attributes: { 'medelement_specialist_code' => 'specialist-2' })
    appointment.update!(resource: replacement)

    expect do
      described_class.new(
        entity_type: 'appointment', entity_id: appointment.id, event_name: 'appointment_updated',
        account_id: account.id, actor_descriptor: { type: 'Captain::Assistant', id: assistant.id },
        event_key: 'appointment:updated:patient-write-second',
        change: { desired_attributes: described_class.appointment_event_snapshot(appointment) }
      ).perform
    end.to raise_error(Scheduling::Error) { |error| expect(error.code).to eq('MEDELEMENT_COMMAND_IN_PROGRESS') }

    expect(first.reload).to be_awaiting_phone_refresh
    expect do
      Integrations::Medelement::ProviderCommands::CancelService.new(command: first, actor: actor).perform
    end.to raise_error(Scheduling::Error) { |error| expect(error.code).to eq('MEDELEMENT_COMMAND_NOT_CANCELLABLE') }
    expect(Integrations::Medelement::ProviderCommand.where(appointment: appointment).count).to eq(1)
  end

  it 'does not clear a Captain booking review state while a retried command is still queued' do
    assistant = create(:captain_assistant, account: account)
    status = Integrations::Medelement::AppointmentProviderStatus
    event = {
      entity_type: 'appointment', entity_id: appointment.id, event_name: 'appointment_created',
      account_id: account.id, actor_descriptor: { type: 'Captain::Assistant', id: assistant.id },
      event_key: 'appointment:created:captain-retry'
    }
    command = described_class.new(**event).perform
    status.persist!(appointment, status::UNKNOWN, command: command)

    retried = described_class.new(**event).perform

    expect(retried).to eq(command)
    expect(appointment.reload.custom_attributes[status::ATTRIBUTE_KEY]).to eq(status::UNKNOWN)
  end

  it 'does not rebind a replacement booking when its old Captain create event is delivered again' do
    assistant = create(:captain_assistant, account: account)
    status = Integrations::Medelement::AppointmentProviderStatus
    event = {
      entity_type: 'appointment', entity_id: appointment.id, event_name: 'appointment_created',
      account_id: account.id, actor_descriptor: { type: 'Captain::Assistant', id: assistant.id },
      event_key: 'appointment:created:captain-original',
      change: { desired_attributes: described_class.appointment_event_snapshot(appointment) }
    }
    original = described_class.new(**event).perform
    original.update!(status: 'succeeded', provider_reception_code: 'old-reception')

    replacement = create(
      :scheduling_resource,
      account: account,
      custom_attributes: { 'medelement_specialist_code' => 'specialist-2' }
    )
    appointment.update!(
      resource: replacement,
      custom_attributes: appointment.custom_attributes.merge(
        status::COMMAND_ID_KEY => original.id + 1,
        status::ATTRIBUTE_KEY => status::PENDING
      )
    )

    expect(described_class.new(**event).perform.id).to eq(original.id)
    expect(appointment.reload.resource_id).to eq(replacement.id)
    expect(appointment.custom_attributes[status::COMMAND_ID_KEY]).to eq(original.id + 1)
    expect(appointment.custom_attributes[status::ATTRIBUTE_KEY]).to eq(status::PENDING)
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

  it 'keeps service and custom attribute updates local for an existing provider reception' do
    appointment.update!(
      external_ref: 'medelement:reception:reception-1',
      custom_attributes: appointment.custom_attributes.merge('medelement_reception_code' => 'reception-1')
    )

    result = described_class.new(
      entity_type: 'appointment',
      entity_id: appointment.id,
      event_name: 'appointment.updated',
      actor_id: actor.id,
      change: {
        changed_attributes: {
          'service_id' => [nil, 42],
          'custom_attributes' => [{ 'note' => 'before' }, { 'note' => 'after' }]
        },
        desired_attributes: described_class.appointment_event_snapshot(appointment)
      }
    ).perform

    expect(result).to be_nil
    expect(Integrations::Medelement::ProviderCommand.where(appointment: appointment)).to be_empty
  end

  {
    'metadata-only' => { 'custom_attributes' => [{ 'internal' => 'before' }, { 'internal' => 'after' }] },
    'service-only' => { 'service_id' => [1, 2] },
    'cabinet-only' => { 'custom_attributes' => [{ 'medelement_cabinet_code' => 'cabinet-1' }, { 'medelement_cabinet_code' => 'cabinet-2' }] },
    'comment-only' => { 'client_comment' => %w[before after] }
  }.each do |name, changed_attributes|
    it "does not create a provider move for a #{name} update" do
      appointment.update!(
        external_ref: 'medelement:reception:reception-1',
        custom_attributes: appointment.custom_attributes.merge('medelement_reception_code' => 'reception-1')
      )

      result = described_class.new(
        entity_type: 'appointment',
        entity_id: appointment.id,
        event_name: 'appointment.updated',
        actor_id: actor.id,
        change: {
          changed_attributes: changed_attributes,
          desired_attributes: described_class.appointment_event_snapshot(appointment)
        }
      ).perform

      expect(result).to be_nil
      expect(Integrations::Medelement::ProviderCommand.where(appointment: appointment)).to be_empty
      expect(Integrations::Medelement::ProviderCommandConfirmationJob).not_to have_been_enqueued
    end
  end

  it 'does not create a provider move when time and resource values are unchanged' do
    appointment.update!(
      external_ref: 'medelement:reception:reception-1',
      custom_attributes: appointment.custom_attributes.merge('medelement_reception_code' => 'reception-1')
    )

    result = described_class.new(
      entity_type: 'appointment',
      entity_id: appointment.id,
      event_name: 'appointment.updated',
      actor_id: actor.id,
      change: {
        changed_attributes: {
          'starts_at' => [appointment.starts_at, appointment.starts_at.iso8601],
          'ends_at' => [appointment.ends_at, appointment.ends_at.iso8601],
          'resource_id' => [appointment.resource_id, appointment.resource_id.to_s]
        },
        desired_attributes: described_class.appointment_event_snapshot(appointment)
      }
    ).perform

    expect(result).to be_nil
    expect(Integrations::Medelement::ProviderCommand.where(appointment: appointment)).to be_empty
  end

  it 'creates exactly one provider move for a real resource change' do
    previous_resource_id = appointment.resource_id
    new_resource = create(
      :scheduling_resource,
      account: account,
      custom_attributes: {
        'medelement_specialist_code' => 'specialist-2',
        'medelement_cabinets' => [{ 'companyCabinetCode' => 'cabinet-1' }]
      }
    )
    appointment.update!(
      resource: new_resource,
      external_ref: 'medelement:reception:reception-1',
      custom_attributes: appointment.custom_attributes.merge('medelement_reception_code' => 'reception-1')
    )

    expect do
      command = described_class.new(
        entity_type: 'appointment',
        entity_id: appointment.id,
        event_name: 'appointment.updated',
        actor_id: actor.id,
        change: {
          changed_attributes: { 'resource_id' => [previous_resource_id, new_resource.id] },
          desired_attributes: described_class.appointment_event_snapshot(appointment)
        }
      ).perform
      expect(command).to have_attributes(operation: 'move_reception', appointment_id: appointment.id)
    end.to change(Integrations::Medelement::ProviderCommand, :count).by(1)
    expect(Integrations::Medelement::ProviderCommandConfirmationJob).to have_been_enqueued.exactly(:once)
  end

  it 'does not create a removal command while the hook keeps receptions on cancel (default)' do
    appointment.update!(
      source: 'medelement',
      external_ref: 'medelement:reception:reception-1',
      custom_attributes: appointment.custom_attributes.merge('medelement_reception_code' => 'reception-1'),
      status: 'cancelled',
      payment_status: 'cancelled'
    )

    expect do
      command = described_class.new(
        entity_type: 'appointment', entity_id: appointment.id, event_name: 'appointment_cancelled', actor_id: actor.id,
        change: { changed_attributes: { 'status' => %w[scheduled cancelled] }, desired_attributes: { 'status' => 'cancelled' } }
      ).perform
      expect(command).to be_nil
    end.not_to change(Integrations::Medelement::ProviderCommand, :count)
    expect(Integrations::Medelement::ProviderCommandConfirmationJob).not_to have_been_enqueued
  end

  it 'creates an immediate removal command for a locally cancelled provider reception' do
    hook.update!(settings: hook.settings.merge('remove_reception_on_cancel' => true))
    appointment.update!(
      source: 'medelement',
      external_ref: 'medelement:reception:reception-1',
      custom_attributes: appointment.custom_attributes.merge(
        'medelement_reception_code' => 'reception-1',
        Integrations::Medelement::AppointmentProviderStatus::CANCELLATION_COMMAND_ID_KEY => -1
      ),
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
    expect(appointment.reload.custom_attributes).to include(
      Integrations::Medelement::AppointmentProviderStatus::CANCELLATION_COMMAND_ID_KEY => command.id
    )
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
