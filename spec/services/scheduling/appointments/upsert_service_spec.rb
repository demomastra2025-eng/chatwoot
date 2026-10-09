require 'rails_helper'

RSpec.describe Scheduling::Appointments::UpsertService do
  let(:account) { create(:account) }
  let(:resource) { create(:scheduling_resource, account: account) }
  let(:appointment) { create(:scheduling_appointment, account: account, resource: resource) }

  def perform(params)
    described_class.new(account: account, appointment: appointment, params: params).perform
  end

  it 'marks new Captain appointments and keeps staff-created appointments manual' do
    account.enable_features!('scheduling')
    assistant = create(:captain_assistant, account: account)
    contact = create(:contact, account: account)
    starts_at = 2.days.from_now.in_time_zone(resource.timezone).change(hour: 10, min: 0)
    next_starts_at = starts_at + 1.day
    [starts_at.wday, next_starts_at.wday].uniq.each do |weekday|
      create(:scheduling_work_rule, resource: resource, weekday: weekday)
    end
    params = { resource_id: resource.id, contact_id: contact.id, starts_at: starts_at, duration_min: 30 }

    captain_appointment = described_class.new(account: account, params: params, actor: assistant).perform
    staff_appointment = described_class.new(account: account, params: params.merge(starts_at: next_starts_at),
                                            actor: create(:user, account: account)).perform

    expect(captain_appointment.reload.source).to eq('captain')
    expect(staff_appointment.reload.source).to eq('manual')
  end

  # Cancellation guards below belong to the removal flow (remove_reception_on_cancel on). The local-only default
  # is proven in spec/services/integrations/medelement/local_status_provider_boundary_spec.rb.
  def medelement_hook_settings(write_enabled: false)
    attributes_for(:integrations_hook, :medelement)[:settings].merge(
      'write_enabled' => write_enabled, 'remove_reception_on_cancel' => true
    )
  end

  def enable_reception_removal!
    account.enable_features!('scheduling')
    create(:integrations_hook, :medelement, account: account, settings: medelement_hook_settings)
  end

  it 'dispatches persisted update changes before reloading the appointment' do
    dispatcher = Rails.configuration.dispatcher
    allow(dispatcher).to receive(:dispatch)

    perform(client_comment: 'Changed')

    expect(dispatcher).to have_received(:dispatch).with(
      Events::Types::APPOINTMENT_UPDATED,
      anything,
      hash_including(
        appointment: appointment,
        changed_attributes: hash_including('client_comment' => [nil, 'Changed'])
      )
    )
  end

  it 'keeps an unconfirmed Medelement booking visible instead of cancelling without a provider ID' do
    enable_reception_removal!
    status = Integrations::Medelement::AppointmentProviderStatus
    appointment.update!(custom_attributes: appointment.custom_attributes.merge(status::ATTRIBUTE_KEY => status::UNKNOWN))

    expect { perform(status: 'cancelled') }.to raise_error(Scheduling::Error) do |error|
      expect(error.code).to eq('MEDELEMENT_BOOKING_REQUIRES_VERIFICATION')
    end
    expect(appointment.reload).to have_attributes(status: 'scheduled', external_ref: nil)
    expect(appointment.custom_attributes[status::ATTRIBUTE_KEY]).to eq(status::UNKNOWN)
  end

  it 'blocks cancellation when a reception write started before the local status was projected' do
    Integrations::Medelement::ProviderCommand.create!(
      account: account, appointment: appointment, contact: appointment.contact, operation: 'create_reception',
      company_cabinet_code: 'cabinet-1', idempotency_key: SecureRandom.uuid,
      status: 'provider_status_unknown', execution_state: { 'write_phase' => 'reception_create' }
    )

    expect { perform(status: 'cancelled') }.to raise_error(Scheduling::Error) do |error|
      expect(error.code).to eq('MEDELEMENT_BOOKING_REQUIRES_VERIFICATION')
    end
    expect(appointment.reload.status).to eq('scheduled')
  end

  it 'rejects a zero reception ID even when the provider status says succeeded' do
    enable_reception_removal!
    status = Integrations::Medelement::AppointmentProviderStatus
    appointment.update!(
      external_ref: 'medelement:reception:0',
      custom_attributes: appointment.custom_attributes.merge(
        status::ATTRIBUTE_KEY => status::SUCCEEDED, 'medelement_reception_code' => '0'
      )
    )

    expect { perform(status: 'cancelled') }.to raise_error(Scheduling::Error) do |error|
      expect(error.code).to eq('MEDELEMENT_BOOKING_REQUIRES_VERIFICATION')
    end
    expect(appointment.reload.status).to eq('scheduled')
  end

  it 'does not cancel a confirmed reception when provider writes are disabled' do
    status = Integrations::Medelement::AppointmentProviderStatus
    account.enable_features!('scheduling')
    resource.update!(custom_attributes: resource.custom_attributes.merge('medelement_specialist_code' => 'specialist-1'))
    hook = create(:integrations_hook, :medelement, account: account, settings: medelement_hook_settings(write_enabled: true))
    hook.update!(settings: hook.settings.merge('write_enabled' => false))
    appointment.update!(
      external_ref: 'medelement:reception:created-1',
      custom_attributes: appointment.custom_attributes.merge(
        status::ATTRIBUTE_KEY => status::SUCCEEDED, 'medelement_reception_code' => 'created-1'
      )
    )

    cancellation = described_class.new(
      account: account, appointment: appointment, params: { status: 'cancelled' }, actor: create(:user, account: account)
    )
    expect { cancellation.perform }.to raise_error(Scheduling::Error) do |error|
      expect(error.code).to eq('MEDELEMENT_BOOKING_REQUIRES_VERIFICATION')
    end
    expect(appointment.reload.status).to eq('scheduled')
  end

  it 'does not cancel a legacy appointment with a MedElement reference but no provider status' do
    enable_reception_removal!
    appointment.update!(external_ref: 'medelement:reception:created-1')

    expect { perform(status: 'cancelled') }.to raise_error(Scheduling::Error) do |error|
      expect(error.code).to eq('MEDELEMENT_BOOKING_REQUIRES_VERIFICATION')
    end
    expect(appointment.reload.status).to eq('scheduled')
  end

  it 'blocks cancellation of a previously confirmed reception while a newer provider change is unknown' do
    enable_reception_removal!
    status = Integrations::Medelement::AppointmentProviderStatus
    appointment.update!(
      external_ref: 'medelement:reception:created-1',
      custom_attributes: appointment.custom_attributes.merge(
        status::ATTRIBUTE_KEY => status::UNKNOWN, 'medelement_reception_code' => 'created-1'
      )
    )

    expect { perform(status: 'cancelled') }.to raise_error(Scheduling::Error) do |error|
      expect(error.code).to eq('MEDELEMENT_BOOKING_REQUIRES_VERIFICATION')
    end
    expect(appointment.reload.status).to eq('scheduled')
  end

  it 'rejects a stale cancellation after the provider outcome becomes unknown in another transaction' do
    stale_appointment = Scheduling::Appointment.find(appointment.id)
    status = Integrations::Medelement::AppointmentProviderStatus
    appointment.update!(custom_attributes: appointment.custom_attributes.merge(status::ATTRIBUTE_KEY => status::UNKNOWN))

    expect do
      described_class.new(account: account, appointment: stale_appointment, params: { status: 'cancelled' }).perform
    end.to raise_error(Scheduling::Error) { |error| expect(error.code).to eq('MEDELEMENT_BOOKING_REQUIRES_VERIFICATION') }
    expect(appointment.reload.status).to eq('scheduled')
  end

  it 'keeps even a verified provider appointment active until provider removal succeeds' do
    status = Integrations::Medelement::AppointmentProviderStatus
    account.enable_features!('scheduling')
    resource.update!(custom_attributes: resource.custom_attributes.merge('medelement_specialist_code' => 'specialist-1'))
    create(:integrations_hook, :medelement, account: account, settings: medelement_hook_settings(write_enabled: true))
    appointment.update!(
      external_ref: 'medelement:reception:created-1',
      custom_attributes: appointment.custom_attributes.merge(
        status::ATTRIBUTE_KEY => status::SUCCEEDED, 'medelement_reception_code' => 'created-1'
      )
    )

    expect do
      described_class.new(
        account: account, appointment: appointment, params: { status: 'cancelled' }, actor: create(:user, account: account)
      ).perform
    end.to raise_error(Scheduling::Error) { |error| expect(error.code).to eq('MEDELEMENT_BOOKING_REQUIRES_VERIFICATION') }

    expect(appointment.reload.status).to eq('scheduled')
  end

  it 'does not cancel a confirmed reception while replacing its provider resource in the same update' do
    status = Integrations::Medelement::AppointmentProviderStatus
    account.enable_features!('scheduling')
    resource.update!(custom_attributes: resource.custom_attributes.merge('medelement_specialist_code' => 'specialist-1'))
    create(:integrations_hook, :medelement, account: account, settings: medelement_hook_settings(write_enabled: true))
    appointment.update!(
      external_ref: 'medelement:reception:created-1',
      custom_attributes: appointment.custom_attributes.merge(
        status::ATTRIBUTE_KEY => status::SUCCEEDED, 'medelement_reception_code' => 'created-1'
      )
    )
    replacement = create(:scheduling_resource, account: account)

    expect do
      described_class.new(
        account: account, appointment: appointment, params: { status: 'cancelled', resource_id: replacement.id },
        actor: create(:user, account: account)
      ).perform
    end.to raise_error(Scheduling::Error) { |error| expect(error.code).to eq('MEDELEMENT_BOOKING_REQUIRES_VERIFICATION') }
    expect(appointment.reload).to have_attributes(status: 'scheduled', resource_id: resource.id)
  end

  it 'does not upgrade a local generic cancellation if the integration toggle changes before execution' do
    account.enable_features!('scheduling')
    hook = create(
      :integrations_hook,
      :medelement,
      account: account,
      settings: attributes_for(:integrations_hook, :medelement)[:settings].merge(
        'write_enabled' => true, 'remove_reception_on_cancel' => false
      )
    )
    status = Integrations::Medelement::AppointmentProviderStatus
    appointment.update!(
      external_ref: 'medelement:reception:created-1',
      custom_attributes: appointment.custom_attributes.merge(
        status::ATTRIBUTE_KEY => status::SUCCEEDED, 'medelement_reception_code' => 'created-1'
      )
    )
    allow(Integrations::Medelement::LocalCancellation).to receive(:local_only?).with(appointment) do
      hook.update!(settings: hook.settings.merge('remove_reception_on_cancel' => true))
      true
    end

    expect { perform(status: 'cancelled') }.to raise_error(Scheduling::Error) do |error|
      expect(error.code).to eq('MEDELEMENT_CANCELLATION_MODE_CHANGED')
    end
    expect(appointment.reload.status).to eq('scheduled')
    expect(Integrations::Medelement::ProviderCommand.where(appointment: appointment)).to be_empty
  end

  it 'cancels a MedElement-linked appointment only locally while the integration keeps receptions' do
    status = Integrations::Medelement::AppointmentProviderStatus
    appointment.update!(
      external_ref: 'medelement:reception:created-1',
      custom_attributes: appointment.custom_attributes.merge(
        status::ATTRIBUTE_KEY => status::SUCCEEDED, 'medelement_reception_code' => 'created-1'
      )
    )

    result = perform(status: 'cancelled', client_comment: 'Not applied, like the cancel endpoint')

    expect(result).to have_attributes(status: 'cancelled', payment_status: 'cancelled')
    expect(result.client_comment).not_to eq('Not applied, like the cancel endpoint')
    expect(result.custom_attributes[Integrations::Medelement::LocalCancellation::MARKER_KEY]).to include('reception_code' => 'created-1')
    expect(Integrations::Medelement::ProviderCommand.where(appointment: appointment)).to be_empty
  end

  it 'keeps a Captain appointment locally with a red review status when the command receipt is unavailable' do
    assistant = create(:captain_assistant, account: account)
    status = Integrations::Medelement::AppointmentProviderStatus
    status.assign_pending!(appointment)
    appointment.save!
    receipt = instance_double(Integrations::Medelement::AppointmentProviderCommandReceiptService, projected_command: nil)
    allow(receipt).to receive(:perform).and_raise(
      Scheduling::Error.new(code: 'MEDELEMENT_COMMAND_RECEIPT_UNAVAILABLE', message: 'Receipt unavailable', status: :service_unavailable)
    )
    service = described_class.new(account: account, appointment: appointment, params: { client_comment: 'Kept locally' }, actor: assistant)
    allow(service).to receive(:persist_appointment!) do
      appointment.update!(client_comment: 'Kept locally')
      service.instance_variable_set(:@provider_receipt_service, receipt)
    end

    expect { service.perform }.to raise_error(Scheduling::Error, /Receipt unavailable/)
    expect(service.persisted_appointment).to eq(appointment)
    expect(appointment.reload.client_comment).to eq('Kept locally')
    expect(appointment.custom_attributes[status::ATTRIBUTE_KEY]).to eq(status::UNKNOWN)
  end

  it 'marks an unexpected receipt failure for staff review without losing the Captain local booking' do
    assistant = create(:captain_assistant, account: account)
    status = Integrations::Medelement::AppointmentProviderStatus
    status.assign_pending!(appointment)
    appointment.save!
    receipt = instance_double(Integrations::Medelement::AppointmentProviderCommandReceiptService, projected_command: nil)
    allow(receipt).to receive(:perform).and_raise(StandardError, 'Receipt storage failed')
    service = described_class.new(account: account, appointment: appointment, params: { client_comment: 'Kept locally' }, actor: assistant)
    allow(service).to receive(:persist_appointment!) do
      appointment.update!(client_comment: 'Kept locally')
      service.instance_variable_set(:@provider_receipt_service, receipt)
    end

    expect { service.perform }.to raise_error(StandardError, 'Receipt storage failed')
    expect(service.persisted_appointment).to eq(appointment)
    expect(appointment.reload.client_comment).to eq('Kept locally')
    expect(appointment.custom_attributes[status::ATTRIBUTE_KEY]).to eq(status::UNKNOWN)
  end

  context 'when command confirmation raises after its status projection' do
    let(:assistant) { create(:captain_assistant, account: account) }
    let(:status) { Integrations::Medelement::AppointmentProviderStatus }
    let(:command) do
      Integrations::Medelement::ProviderCommand.create!(
        account: account, appointment: appointment, contact: appointment.contact, operation: 'create_reception',
        status: 'awaiting_confirmation', idempotency_key: SecureRandom.uuid, company_cabinet_code: 'cabinet-1',
        desired_starts_at: appointment.starts_at, desired_ends_at: appointment.ends_at,
        execution_state: {
          'request_fingerprint' => 'receipt-fingerprint', 'dispatch_identity' => 'receipt-dispatch',
          'request_snapshot' => { 'version' => 2, 'actor' => { 'type' => 'Captain::Assistant', 'id' => assistant.id },
                                  'reception' => { 'resource_id' => resource.id, 'nomenclature_codes' => [] } }
        }
      )
    end
    let(:receipt) { instance_double(Integrations::Medelement::AppointmentProviderCommandReceiptService, projected_command: command) }
    let(:service) do
      described_class.new(account: account, appointment: appointment, params: { client_comment: 'Kept locally' }, actor: assistant)
    end

    before do
      appointment.update!(custom_attributes: appointment.custom_attributes.merge('medelement_cabinet_code' => 'cabinet-1'))
      status.assign_pending!(appointment)
      appointment.save!
      allow(service).to receive(:persist_appointment!) do
        appointment.update!(client_comment: 'Kept locally')
        service.instance_variable_set(:@provider_receipt_service, receipt)
      end
    end

    it 'keeps the original local slot red and bound to its command' do
      allow(receipt).to receive(:perform) do
        status.persist!(Scheduling::Appointment.find(appointment.id), status::PENDING, command: command)
        raise StandardError, 'Confirmation failed after projection'
      end

      expect { service.perform }.to raise_error(StandardError, 'Confirmation failed after projection')
      expect(service.persisted_appointment).to eq(appointment)
      expect(appointment.reload).to have_attributes(status: 'scheduled', client_comment: 'Kept locally')
      expect(appointment.custom_attributes).to include(status::ATTRIBUTE_KEY => status::UNKNOWN, status::COMMAND_ID_KEY => command.id)
    end

    it 'does not overwrite a replacement command projected before the error returns' do
      command.update!(status: 'succeeded')
      replacement = command.dup
      replacement.idempotency_key = SecureRandom.uuid
      replacement.save!
      allow(receipt).to receive(:perform) do
        status.persist!(Scheduling::Appointment.find(appointment.id), status::PENDING, command: command)
        status.persist!(Scheduling::Appointment.find(appointment.id), status::PENDING, command: replacement)
        raise StandardError, 'Confirmation failed after replacement'
      end

      expect { service.perform }.to raise_error(StandardError, 'Confirmation failed after replacement')
      expect(appointment.reload.custom_attributes).to include(status::ATTRIBUTE_KEY => status::PENDING, status::COMMAND_ID_KEY => replacement.id)
    end

    it 'does not mark the old command red when the local slot changes after projection' do
      replacement = create(:scheduling_resource, account: account)
      allow(receipt).to receive(:perform) do
        status.persist!(Scheduling::Appointment.find(appointment.id), status::PENDING, command: command)
        Scheduling::Appointment.find(appointment.id).update!(resource: replacement)
        raise StandardError, 'Confirmation failed after slot change'
      end

      expect { service.perform }.to raise_error(StandardError, 'Confirmation failed after slot change')
      expect(appointment.reload.custom_attributes).to include(status::ATTRIBUTE_KEY => status::PENDING, status::COMMAND_ID_KEY => command.id)
      expect(appointment.resource_id).to eq(replacement.id)
    end
  end

  it 'does not overwrite a newer provider success when the Captain receipt raises after the local save' do
    assistant = create(:captain_assistant, account: account)
    status = Integrations::Medelement::AppointmentProviderStatus
    status.assign_pending!(appointment)
    appointment.save!
    receipt = instance_double(Integrations::Medelement::AppointmentProviderCommandReceiptService, projected_command: nil)
    allow(receipt).to receive(:perform) do
      status.persist!(Scheduling::Appointment.find(appointment.id), status::SUCCEEDED)
      raise StandardError, 'Receipt storage failed'
    end
    service = described_class.new(account: account, appointment: appointment, params: { client_comment: 'Kept locally' }, actor: assistant)
    allow(service).to receive(:persist_appointment!) do
      appointment.update!(client_comment: 'Kept locally')
      service.instance_variable_set(:@provider_receipt_service, receipt)
    end

    expect { service.perform }.to raise_error(StandardError, 'Receipt storage failed')
    expect(appointment.reload.custom_attributes[status::ATTRIBUTE_KEY]).to eq(status::SUCCEEDED)
  end

  it 'does not mark another booking command unknown when a newer Captain receipt raises' do
    assistant = create(:captain_assistant, account: account)
    status = Integrations::Medelement::AppointmentProviderStatus
    status.assign_pending!(appointment)
    appointment.save!
    receipt = instance_double(Integrations::Medelement::AppointmentProviderCommandReceiptService, projected_command: nil)
    allow(receipt).to receive(:perform) do
      newer = Scheduling::Appointment.find(appointment.id)
      newer.update!(custom_attributes: newer.custom_attributes.merge(status::COMMAND_ID_KEY => 123_456))
      raise StandardError, 'Receipt storage failed'
    end
    service = described_class.new(account: account, appointment: appointment, params: { client_comment: 'Kept locally' }, actor: assistant)
    allow(service).to receive(:persist_appointment!) do
      appointment.update!(client_comment: 'Kept locally')
      service.instance_variable_set(:@provider_receipt_service, receipt)
    end

    expect { service.perform }.to raise_error(StandardError, 'Receipt storage failed')
    expect(appointment.reload.custom_attributes).to include(status::ATTRIBUTE_KEY => status::PENDING, status::COMMAND_ID_KEY => 123_456)
  end

  it 'does not mark a changed booking unknown when an older Captain receipt raises' do
    assistant = create(:captain_assistant, account: account)
    status = Integrations::Medelement::AppointmentProviderStatus
    status.assign_pending!(appointment)
    appointment.save!
    replacement = create(:scheduling_resource, account: account)
    receipt = instance_double(Integrations::Medelement::AppointmentProviderCommandReceiptService, projected_command: nil)
    allow(receipt).to receive(:perform) do
      newer = Scheduling::Appointment.find(appointment.id)
      newer.update!(resource: replacement)
      status.assign_pending!(newer)
      newer.save!
      raise StandardError, 'Receipt storage failed'
    end
    service = described_class.new(account: account, appointment: appointment, params: { client_comment: 'Kept locally' }, actor: assistant)
    allow(service).to receive(:persist_appointment!) do
      appointment.update!(client_comment: 'Kept locally')
      service.instance_variable_set(:@provider_receipt_service, receipt)
    end

    expect { service.perform }.to raise_error(StandardError, 'Receipt storage failed')
    expect(appointment.reload).to have_attributes(resource_id: replacement.id)
    expect(appointment.custom_attributes[status::ATTRIBUTE_KEY]).to eq(status::PENDING)
  end

  it 'rejects generic mutations of imported Medelement appointments' do
    appointment.update!(source: 'medelement', external_ref: 'medelement:reception:upsert')

    expect { perform(client_comment: 'Changed') }.to raise_error(Scheduling::Error) do |error|
      expect(error.code).to eq('APPOINTMENT_READ_ONLY')
    end
    expect(appointment.reload.client_comment).to be_nil
  end

  it 'rejects direct assignment of appointment provenance' do
    expect { perform(source: 'medelement') }.to raise_error(Scheduling::Error) do |error|
      expect(error.code).to eq('APPOINTMENT_SOURCE_READ_ONLY')
    end
    expect(appointment.reload.source).to eq('manual')
  end

  it 'reserves Medelement external references for the provider importer' do
    expect { perform(external_ref: ' medelement:reception:spoofed') }.to raise_error(Scheduling::Error) do |error|
      expect(error.code).to eq('APPOINTMENT_EXTERNAL_REF_RESERVED')
    end
    expect(appointment.reload.external_ref).to be_nil
  end

  it 'rejects provider-owned Medelement metadata in manual appointment custom attributes' do
    request = -> { perform(custom_attributes: { 'medelement_reception_code' => 'spoofed' }) }

    expect(&request).to raise_error(Crm::Error) do |error|
      expect(error.code).to eq('VALIDATION_ERROR')
    end
    expect(appointment.reload.custom_attributes).not_to have_key('medelement_reception_code')
  end

  it 'rejects the provider source mode while preserving unrelated custom attributes' do
    request = -> { perform(custom_attributes: { 'source_mode' => 'imported', 'note' => 'allowed' }) }

    expect(&request).to raise_error(Crm::Error) do |error|
      expect(error.code).to eq('VALIDATION_ERROR')
    end
    expect(appointment.reload.custom_attributes).to be_empty
  end

  it 'stores structured patient names while requiring only the first name locally' do
    perform(client_first_name: 'Айжан', client_last_name: '', client_middle_name: '')

    expect(appointment.reload).to have_attributes(
      client_first_name: 'Айжан',
      client_last_name: nil,
      client_middle_name: nil,
      client_name: 'Айжан'
    )
  end

  it 'does not populate structured identity from contact fields for non-Medelement appointments' do
    appointment.update!(client_first_name: nil, client_last_name: nil, client_middle_name: nil)
    appointment.contact.update!(name: 'Display name', last_name: 'Касымова', middle_name: 'Ерлановна')

    perform({})

    expect(appointment.reload).to have_attributes(
      client_first_name: nil,
      client_last_name: nil,
      client_middle_name: nil
    )
  end

  it 'rejects an unsupported appointment type at the model runtime boundary' do
    expect { perform(appointment_type: 'Терапевт') }.to raise_error(ActiveRecord::RecordInvalid) do |error|
      expect(error.record.errors.details[:appointment_type]).to include(error: :inclusion, value: 'Терапевт')
    end
  end

  context 'when the selected resource belongs to Medelement' do
    let(:valid_phone) { ['+7', '700', '000', '0001'].join }
    let(:appointment) do
      starts_at = 2.days.from_now.in_time_zone(resource.timezone).change(hour: 10, min: 0, sec: 0)
      create(:scheduling_appointment, account: account, resource: resource,
                                      starts_at: starts_at, ends_at: starts_at + 30.minutes)
    end
    let(:service) do
      create(
        :scheduling_service,
        account: account,
        custom_attributes: { 'medelement_nomenclature_code' => 'service-1' }
      )
    end

    before do
      resource.update!(
        custom_attributes: {
          'medelement_specialist_code' => 'specialist-1',
          'medelement_cabinets' => [{ 'companyCabinetCode' => 'cabinet-1' }]
        }
      )
      appointment.update!(
        custom_attributes: appointment.custom_attributes.merge('medelement_cabinet_code' => 'cabinet-1')
      )
    end

    it 'uses structured Medelement contact names when appointment name fields are omitted' do
      appointment.update!(service: nil, custom_attributes: appointment.custom_attributes.except('service_ids', 'services'))
      appointment.contact.update!(
        name: 'Жандаулет Гусман',
        last_name: nil,
        middle_name: nil,
        phone_number: ['+7', '700', '000', '0001'].join,
        custom_attributes: appointment.contact.custom_attributes.merge(
          'medelement_first_name' => 'Жандаулет',
          'medelement_last_name' => 'Гусман'
        )
      )

      perform({})

      expect(appointment.reload).to have_attributes(
        client_first_name: 'Жандаулет',
        client_last_name: 'Гусман',
        client_middle_name: nil,
        client_name: 'Жандаулет Гусман'
      )
    end

    it 'uses structured top-level contact names when appointment name fields are omitted' do
      appointment.update!(service: nil, custom_attributes: appointment.custom_attributes.except('service_ids', 'services'))
      appointment.contact.update!(
        name: 'Айжан',
        last_name: 'Касымова',
        middle_name: 'Ерлановна',
        phone_number: ['+7', '700', '000', '0001'].join
      )

      perform({})

      expect(appointment.reload).to have_attributes(
        client_first_name: 'Айжан',
        client_last_name: 'Касымова',
        client_middle_name: 'Ерлановна',
        client_name: 'Айжан Касымова Ерлановна'
      )
    end

    it 'does not mix a partial Medelement custom identity with a full display name' do
      appointment.update!(service: nil, custom_attributes: appointment.custom_attributes.except('service_ids', 'services'))
      appointment.contact.update!(
        name: 'Жандаулет Гусман',
        last_name: nil,
        phone_number: ['+7', '700', '000', '0001'].join,
        custom_attributes: appointment.contact.custom_attributes.merge('medelement_last_name' => 'Гусман')
      )

      expect { perform({}) }.to raise_error(Scheduling::Error) do |error|
        expect(error.code).to eq('MEDELEMENT_PATIENT_NAME_INCOMPLETE')
      end
      expect(appointment.reload.client_first_name).to be_nil
    end

    it 'does not fill a missing Medelement custom last name from top-level contact fields' do
      appointment.update!(service: nil, custom_attributes: appointment.custom_attributes.except('service_ids', 'services'))
      appointment.contact.update!(
        name: 'Жандаулет',
        last_name: 'Гусман',
        phone_number: ['+7', '700', '000', '0001'].join,
        custom_attributes: appointment.contact.custom_attributes.merge('medelement_first_name' => 'Жандаулет')
      )

      expect { perform({}) }.to raise_error(Scheduling::Error) do |error|
        expect(error.code).to eq('MEDELEMENT_PATIENT_NAME_INCOMPLETE')
      end
      expect(appointment.reload.client_last_name).to be_nil
    end

    it 'rejects an appointment without a patient last name before persistence' do
      request = -> { perform(client_first_name: 'Айжан', client_last_name: '', client_phone: '+77000000001') }

      expect(&request).to raise_error(Scheduling::Error) do |error|
        expect(error.code).to eq('MEDELEMENT_PATIENT_NAME_INCOMPLETE')
      end

      expect(appointment.reload.client_first_name).to be_nil
    end

    it 'rejects an appointment without a valid Kazakhstan phone before persistence' do
      request = -> { perform(client_first_name: 'Айжан', client_last_name: 'Касымова', client_phone: '') }

      expect(&request).to raise_error(Scheduling::Error) do |error|
        expect(error.code).to eq('MEDELEMENT_PATIENT_PHONE_INVALID')
      end

      expect(appointment.reload.client_first_name).to be_nil
    end

    it 'rejects an appointment without a Medelement cabinet before persistence' do
      appointment.update!(
        service: nil,
        custom_attributes: appointment.custom_attributes.except('service_ids', 'services', 'medelement_cabinet_code')
      )

      expect do
        perform(resource_id: resource.id, client_first_name: 'Айжан', client_last_name: 'Касымова',
                client_phone: ['+7', '700', '000', '0001'].join)
      end.to raise_error(Scheduling::Error) { |error| expect(error.code).to eq('MEDELEMENT_CABINET_REQUIRED') }
    end

    it 'rejects a Medelement cabinet that does not belong to the selected specialist' do
      appointment.update!(
        service: nil,
        custom_attributes: appointment.custom_attributes.except('service_ids', 'services')
                                                .merge('medelement_cabinet_code' => 'foreign-cabinet')
      )

      expect do
        perform(resource_id: resource.id, client_first_name: 'Айжан', client_last_name: 'Касымова',
                client_phone: ['+7', '700', '000', '0001'].join)
      end.to raise_error(Scheduling::Error) { |error| expect(error.code).to eq('MEDELEMENT_CABINET_INVALID') }
    end

    %w[companyCabinetCode company_cabinet_code COMPANY_CABINET_CODE].each do |cabinet_key|
      it "accepts the #{cabinet_key} resource cabinet format" do
        resource.update!(
          custom_attributes: resource.custom_attributes.merge(
            'medelement_cabinets' => [{ cabinet_key => 'cabinet-1' }]
          )
        )
        appointment.update!(
          service: nil,
          custom_attributes: appointment.custom_attributes.except('service_ids', 'services')
        )

        expect do
          perform(
            resource_id: resource.id,
            client_first_name: 'Айжан',
            client_last_name: 'Касымова',
            client_phone: valid_phone
          )
        end.not_to raise_error
      end
    end

    it 'allows an unrelated update to a legacy appointment without a cabinet' do
      appointment.update!(
        service: nil,
        client_first_name: 'Айжан',
        client_last_name: 'Касымова',
        client_phone: ['+7', '700', '000', '0001'].join,
        custom_attributes: appointment.custom_attributes.except('service_ids', 'services', 'medelement_cabinet_code')
      )

      perform(client_comment: 'Legacy appointment note')

      expect(appointment.reload).to have_attributes(client_comment: 'Legacy appointment note')
      expect(appointment.custom_attributes).not_to have_key('medelement_cabinet_code')
    end

    it 'accepts an appointment without a selected service' do
      appointment.update!(
        service: nil,
        custom_attributes: appointment.custom_attributes.except('service_ids', 'services')
      )
      perform(client_first_name: 'Айжан', client_last_name: 'Касымова', client_phone: '+77000000001')

      expect(appointment.reload).to have_attributes(
        client_first_name: 'Айжан',
        service_id: nil
      )
    end

    it 'rejects a service that is not linked to Medelement before persistence' do
      original_service_id = appointment.service_id
      unmapped_service = create(:scheduling_service, account: account)
      request = lambda do
        perform(
          client_first_name: 'Айжан',
          client_last_name: 'Касымова',
          client_phone: '+77000000001',
          service_id: unmapped_service.id
        )
      end

      expect(&request).to raise_error(Scheduling::Error) do |error|
        expect(error.code).to eq('MEDELEMENT_SERVICE_UNMAPPED')
      end

      expect(appointment.reload.service_id).to eq(original_service_id)
    end

    it 'accepts a complete provider patient identity and mapped service' do
      perform(
        client_first_name: 'Айжан',
        client_last_name: 'Касымова',
        client_phone: '+77000000001',
        service_id: service.id
      )

      expect(appointment.reload).to have_attributes(
        client_first_name: 'Айжан',
        client_last_name: 'Касымова',
        client_phone: '+77000000001',
        service_id: service.id
      )
      expect(appointment.custom_attributes).to include(
        'medelement_service_binding' => 'local_only',
        'medelement_local_nomenclature_codes' => ['service-1'],
        'medelement_provider_nomenclature_codes' => []
      )
    end

    it 'clears the local-only binding when the user removes the selected service' do
      appointment.update!(
        service: service,
        custom_attributes: appointment.custom_attributes.merge(
          'service_ids' => [service.id],
          'medelement_service_binding' => 'local_only',
          'medelement_local_nomenclature_codes' => ['service-1'],
          'medelement_provider_nomenclature_codes' => []
        )
      )

      perform(
        client_first_name: 'Айжан',
        client_last_name: 'Касымова',
        client_phone: '+77000000001',
        service_ids: []
      )

      expect(appointment.reload.service_id).to be_nil
      expect(appointment.custom_attributes).not_to include(
        'medelement_service_binding',
        'medelement_local_nomenclature_codes',
        'medelement_provider_nomenclature_codes'
      )
    end

    it 'accepts a mapped service without a specialist price link' do
      other_resource = create(:scheduling_resource, account: account)
      create(:scheduling_service_price, account: account, resource: other_resource, service: service)

      perform(
        client_first_name: 'Айжан',
        client_last_name: 'Касымова',
        client_phone: ['+7', '700', '000', '0001'].join,
        service_id: service.id
      )

      expect(appointment.reload.service_id).to eq(service.id)
    end

    it 'accepts only linked services when the specialist has explicit links' do
      linked_service = create(
        :scheduling_service,
        account: account,
        custom_attributes: { 'medelement_nomenclature_code' => 'service-2' }
      )
      create(:scheduling_service_price, account: account, resource: resource, service: linked_service)

      request = lambda do
        perform(
          client_first_name: 'Айжан',
          client_last_name: 'Касымова',
          client_phone: ['+7', '700', '000', '0001'].join,
          service_id: service.id
        )
      end

      expect(&request).to raise_error(Scheduling::Error) do |error|
        expect(error.code).to eq('MEDELEMENT_SERVICE_UNAVAILABLE')
      end

      perform(
        client_first_name: 'Айжан',
        client_last_name: 'Касымова',
        client_phone: ['+7', '700', '000', '0001'].join,
        service_id: linked_service.id
      )

      expect(appointment.reload.service_id).to eq(linked_service.id)
    end

    it 'fails closed at the mutation boundary when provider availability is unavailable' do
      original_starts_at = appointment.starts_at
      moved_starts_at = original_starts_at + 1.hour
      appointment.update!(
        service: nil,
        client_first_name: 'Айжан',
        client_last_name: 'Касымова',
        external_ref: 'medelement:reception:reception-1',
        custom_attributes: appointment.custom_attributes.except('service_ids', 'services', 'medelement_reception_code')
      )
      local_result = instance_double(Scheduling::AvailabilityService::Result, available?: true)
      local_service = instance_double(Scheduling::AvailabilityService, availability_result: local_result)
      allow(Scheduling::AvailabilityService).to receive(:new).and_return(local_service)
      provider_result = Integrations::Medelement::ResourceAvailabilityService::Result.new(
        status: 'unavailable',
        checked_at: Time.current,
        slots: [],
        reason: 'provider_unavailable'
      )
      provider_service = instance_double(Integrations::Medelement::ResourceAvailabilityService, perform: provider_result)
      expect(Integrations::Medelement::ResourceAvailabilityService).to receive(:new).with(
        hash_including(cabinet_code: 'cabinet-1', exclude_reception_code: 'reception-1')
      ).and_return(provider_service)

      expect do
        perform(
          starts_at: moved_starts_at,
          ends_at: appointment.ends_at + 1.hour,
          client_phone: '+77001234567'
        )
      end.to raise_error(Scheduling::Error) { |error| expect(error.code).to eq('MEDELEMENT_AVAILABILITY_UNVERIFIED') }

      expect(appointment.reload.starts_at).to eq(original_starts_at)
    end

    it 'revalidates Medelement availability when only the selected cabinet changes' do
      appointment.update!(
        service: nil,
        client_first_name: 'Айжан',
        client_last_name: 'Касымова',
        custom_attributes: appointment.custom_attributes.except('service_ids', 'services').merge(
          'medelement_reception_code' => 'reception-1',
          'medelement_cabinet_code' => 'cabinet-1'
        )
      )
      resource.update!(
        custom_attributes: resource.custom_attributes.merge(
          'medelement_cabinets' => [
            { 'companyCabinetCode' => 'cabinet-1' },
            { 'companyCabinetCode' => 'cabinet-2' }
          ]
        )
      )
      local_result = instance_double(Scheduling::AvailabilityService::Result, available?: true)
      allow(Scheduling::AvailabilityService).to receive(:new).and_return(
        instance_double(Scheduling::AvailabilityService, availability_result: local_result)
      )
      provider_result = Integrations::Medelement::ResourceAvailabilityService::Result.new(
        status: 'fresh', checked_at: Time.current, slots: [], reason: nil
      )
      expect(Integrations::Medelement::ResourceAvailabilityService).to receive(:new).with(
        hash_including(cabinet_code: 'cabinet-2', exclude_reception_code: 'reception-1')
      ).and_return(instance_double(Integrations::Medelement::ResourceAvailabilityService, perform: provider_result))

      expect do
        perform(
          custom_attributes: appointment.custom_attributes.merge('medelement_cabinet_code' => 'cabinet-2'),
          client_phone: '+77001234567'
        )
      end.to raise_error(Scheduling::Error) { |error| expect(error.code).to eq('APPOINTMENT_SLOT_UNAVAILABLE') }

      expect(appointment.reload.custom_attributes['medelement_cabinet_code']).to eq('cabinet-1')
    end

    it 'allows cancellation of a legacy incomplete appointment' do
      perform(status: 'cancelled')

      expect(appointment.reload.status).to eq('cancelled')
    end
  end

  it 'composes the display name from all structured patient name fields' do
    perform(
      client_first_name: 'Айжан',
      client_last_name: 'Касымова',
      client_middle_name: 'Ерлановна'
    )

    expect(appointment.reload).to have_attributes(
      client_first_name: 'Айжан',
      client_last_name: 'Касымова',
      client_middle_name: 'Ерлановна',
      client_name: 'Айжан Касымова Ерлановна'
    )
  end
end
