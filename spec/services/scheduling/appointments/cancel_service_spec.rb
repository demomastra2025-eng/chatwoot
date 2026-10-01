require 'rails_helper'

RSpec.describe Scheduling::Appointments::CancelService do
  include ActiveJob::TestHelper

  let(:account) { create(:account).tap { |record| record.enable_features!('scheduling') } }
  let(:actor) { create(:user) }
  let!(:account_user) { create(:account_user, account: account, user: actor) }
  let(:contact) do
    create(
      :contact,
      account: account,
      phone_number: ['+7', '700', '000', '0001'].join,
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
      source: 'medelement',
      external_ref: 'medelement:reception:reception-1',
      status: 'scheduled',
      payment_status: 'awaiting_payment',
      custom_attributes: {
        'medelement_reception_code' => 'reception-1',
        'medelement_cabinet_code' => 'cabinet-1'
      }
    )
  end

  before do
    account_user
    clear_enqueued_jobs
  end

  # The removal flow runs only when the hook opts into remove_reception_on_cancel.
  def create_medelement_hook(write_enabled: true, remove_reception_on_cancel: true)
    settings = attributes_for(:integrations_hook, :medelement)[:settings].merge(
      'write_enabled' => write_enabled, 'remove_reception_on_cancel' => remove_reception_on_cancel
    )
    create(:integrations_hook, :medelement, account: account, settings: settings)
  end

  it 'queues a confirmed provider removal without cancelling local state first' do
    create_medelement_hook

    result = described_class.new(appointment: appointment, actor: actor).perform
    command = result.medelement_provider_command_receipt

    expect(command).to have_attributes(
      appointment_id: appointment.id,
      operation: 'remove_reception',
      requested_by_id: actor.id
    )
    expect(command.confirmation_request).to have_attributes(status: 'confirmed', resolution_source: 'system')
    expect(Integrations::Medelement::ProviderCommandConfirmationJob).to have_been_enqueued.with(command.confirmation_request_id)
    expect(result).to have_attributes(status: 'scheduled', payment_status: 'awaiting_payment')
    expect(result.custom_attributes['medelement_provider_sync_status']).to eq('pending')
  end

  it 'fails explicitly when provider cancellation cannot be queued' do
    create_medelement_hook(write_enabled: false)

    expect do
      described_class.new(appointment: appointment, actor: actor).perform
    end.to raise_error(Scheduling::Error) { |error| expect(error.code).to eq('MEDELEMENT_CANCELLATION_UNAVAILABLE') }

    expect(appointment.reload).to have_attributes(status: 'scheduled', payment_status: 'awaiting_payment')
  end

  it 'creates a new provider command after an earlier cancellation command failed' do
    create_medelement_hook
    first_command = described_class.new(appointment: appointment, actor: actor).perform.medelement_provider_command_receipt
    first_command.update!(status: 'failed', executed_at: Time.current)
    clear_enqueued_jobs

    result = described_class.new(appointment: appointment.reload, actor: actor).perform
    retry_command = result.medelement_provider_command_receipt

    expect(retry_command.id).not_to eq(first_command.id)
    expect(retry_command.idempotency_key).not_to eq(first_command.idempotency_key)
    expect(Integrations::Medelement::ProviderCommandConfirmationJob).to have_been_enqueued.with(
      retry_command.confirmation_request_id
    )
  end

  it 'normalizes payment state for an appointment that is already cancelled' do
    appointment.update!(status: 'cancelled', payment_status: 'awaiting_payment')

    result = described_class.new(appointment: appointment, actor: actor).perform

    expect(result).to have_attributes(status: 'cancelled', payment_status: 'cancelled')
    expect(Integrations::Medelement::ProviderCommand.where(appointment: appointment)).to be_empty
  end

  it 'requires verification when a failed provider create write may have reached MedElement' do
    status = Integrations::Medelement::AppointmentProviderStatus
    appointment.update!(
      source: 'manual',
      external_ref: nil,
      custom_attributes: { status::ATTRIBUTE_KEY => status::UNKNOWN }
    )
    Integrations::Medelement::ProviderCommand.create!(
      account: account,
      appointment: appointment,
      contact: contact,
      operation: 'create_reception',
      company_cabinet_code: 'cabinet-1',
      idempotency_key: SecureRandom.uuid,
      status: 'failed',
      execution_state: { 'write_phase' => 'reception_create' }
    )

    cancel_service = described_class.new(appointment: appointment, actor: actor)

    expect { cancel_service.perform }.to raise_error(Scheduling::Error) do |error|
      expect(error.code).to eq('MEDELEMENT_BOOKING_REQUIRES_VERIFICATION')
    end
    expect(appointment.reload.status).to eq('scheduled')
    expect(
      Integrations::Medelement::ProviderCommand.where(appointment: appointment, operation: 'remove_reception')
    ).to be_empty
  end

  it 'cancels a local appointment immediately' do
    local_resource = create(:scheduling_resource, account: account)
    local_appointment = create(
      :scheduling_appointment,
      account: account,
      contact: contact,
      resource: local_resource,
      source: 'manual',
      status: 'scheduled',
      payment_status: 'awaiting_payment'
    )

    result = described_class.new(appointment: local_appointment, actor: actor).perform

    expect(result).to have_attributes(status: 'cancelled', payment_status: 'cancelled')
  end

  it 'holds a confirmed local MedElement booking until removal is verified' do
    create_medelement_hook
    local_appointment = appointment
    local_appointment.update!(source: 'manual', custom_attributes: local_appointment.custom_attributes.merge(
      Integrations::Medelement::AppointmentProviderStatus::ATTRIBUTE_KEY => 'succeeded'
    ))

    result = described_class.new(appointment: local_appointment, actor: actor).perform

    expect(result).to have_attributes(status: 'scheduled', payment_status: 'awaiting_payment')
    expect(Scheduling::Appointment.active_statuses.exists?(id: result.id)).to be(true)
    expect(result.custom_attributes['medelement_provider_sync_status']).to eq('pending')
    expect(result.medelement_provider_command_receipt).to have_attributes(operation: 'remove_reception')
    expect do
      described_class.new(appointment: local_appointment.reload, actor: actor).perform
    end.to raise_error(Scheduling::Error) { |error| expect(error.code).to eq('MEDELEMENT_BOOKING_REQUIRES_VERIFICATION') }
    expect(Integrations::Medelement::ProviderCommand.where(appointment: local_appointment, operation: 'remove_reception').count).to eq(1)
  end

  it 'holds a confirmed local MedElement slot when the write hook vanishes before command creation' do
    create_medelement_hook(write_enabled: false)
    local_appointment = appointment
    local_appointment.update!(source: 'manual', custom_attributes: local_appointment.custom_attributes.merge(
      Integrations::Medelement::AppointmentProviderStatus::ATTRIBUTE_KEY => 'succeeded'
    ))

    expect do
      described_class.new(appointment: local_appointment, actor: actor).perform
    end.to raise_error(Scheduling::Error) { |error| expect(error.code).to eq('MEDELEMENT_CANCELLATION_UNAVAILABLE') }
    expect(local_appointment.reload.status).to eq('scheduled')
  end

  it 'does not remove a local reception with an unknown provider outcome' do
    create_medelement_hook
    local_appointment = appointment
    local_appointment.update!(source: 'manual', custom_attributes: local_appointment.custom_attributes.merge(
      Integrations::Medelement::AppointmentProviderStatus::ATTRIBUTE_KEY => 'provider_status_unknown'
    ))

    expect do
      described_class.new(appointment: local_appointment, actor: actor).perform
    end.to raise_error(Scheduling::Error) { |error| expect(error.code).to eq('MEDELEMENT_BOOKING_REQUIRES_VERIFICATION') }
    expect(local_appointment.reload.status).to eq('scheduled')
  end

  context 'when the hook keeps MedElement receptions on cancel (default)' do
    let(:marker_key) { Integrations::Medelement::LocalCancellation::MARKER_KEY }

    it 'cancels a provider appointment only in OneLink, even with writes enabled' do
      create_medelement_hook(remove_reception_on_cancel: false)

      result = described_class.new(appointment: appointment, actor: actor).perform

      expect(result).to have_attributes(status: 'cancelled', payment_status: 'cancelled')
      expect(result.medelement_provider_command_receipt).to be_nil
      expect(result.custom_attributes[marker_key]).to include('reception_code' => 'reception-1')
      expect(Integrations::Medelement::ProviderCommand.where(appointment: appointment)).to be_empty
      expect(Integrations::Medelement::ProviderCommandConfirmationJob).not_to have_been_enqueued
    end

    it 'rejects stale local-only confirmation after the hook switches to provider removal' do
      create_medelement_hook(remove_reception_on_cancel: true)
      commands_before = Integrations::Medelement::ProviderCommand.count

      cancel_service = described_class.new(
        appointment: appointment, actor: actor, expected_medelement_cancellation_mode: 'local_only'
      )

      expect { cancel_service.perform }.to raise_error(Scheduling::Error) do |error|
        expect(error.code).to eq('MEDELEMENT_CANCELLATION_MODE_CHANGED')
        expect(error.status).to eq(409)
      end

      expect(appointment.reload).to have_attributes(status: 'scheduled', payment_status: 'awaiting_payment')
      expect(Integrations::Medelement::ProviderCommand.count).to eq(commands_before)
    end

    it 'cancels locally without any MedElement hook' do
      result = described_class.new(appointment: appointment, actor: actor).perform

      expect(result).to have_attributes(status: 'cancelled', payment_status: 'cancelled')
      expect(result.custom_attributes[marker_key]).to be_present
    end

    it 'cancels a booking with an unknown provider outcome locally' do
      local_appointment = appointment
      local_appointment.update!(source: 'manual', custom_attributes: local_appointment.custom_attributes.merge(
        Integrations::Medelement::AppointmentProviderStatus::ATTRIBUTE_KEY => 'provider_status_unknown'
      ))

      result = described_class.new(appointment: local_appointment, actor: actor).perform

      expect(result.status).to eq('cancelled')
      expect(result.custom_attributes[marker_key]).to be_present
      expect(Integrations::Medelement::ProviderCommand.where(appointment: local_appointment)).to be_empty
    end

    it 'waits for a MedElement command that is still in progress' do
      Integrations::Medelement::ProviderCommand.create!(
        account: account, appointment: appointment, contact: contact, operation: 'move_reception',
        company_cabinet_code: 'cabinet-1', idempotency_key: SecureRandom.uuid, status: 'queued',
        desired_starts_at: appointment.starts_at + 1.hour, desired_ends_at: appointment.ends_at + 1.hour
      )

      expect do
        described_class.new(appointment: appointment, actor: actor).perform
      end.to raise_error(Scheduling::Error) { |error| expect(error.code).to eq('MEDELEMENT_BOOKING_REQUIRES_VERIFICATION') }
      expect(appointment.reload.status).to eq('scheduled')
    end
  end
end
