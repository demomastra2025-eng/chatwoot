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

  it 'queues a confirmed provider removal without cancelling local state first' do
    settings = attributes_for(:integrations_hook, :medelement)[:settings].merge('write_enabled' => true)
    create(:integrations_hook, :medelement, account: account, settings: settings)

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
    expect do
      described_class.new(appointment: appointment, actor: actor).perform
    end.to raise_error(Scheduling::Error) { |error| expect(error.code).to eq('MEDELEMENT_CANCELLATION_UNAVAILABLE') }

    expect(appointment.reload).to have_attributes(status: 'scheduled', payment_status: 'awaiting_payment')
  end

  it 'creates a new provider command after an earlier cancellation command failed' do
    settings = attributes_for(:integrations_hook, :medelement)[:settings].merge('write_enabled' => true)
    create(:integrations_hook, :medelement, account: account, settings: settings)
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
end
