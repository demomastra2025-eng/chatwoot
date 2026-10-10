require 'rails_helper'

RSpec.describe Integrations::Medelement::MissingAppointmentReconciler do
  let(:verification) { Integrations::Medelement::ProviderCommands::ReceptionReceiptVerificationService }
  let(:provider) { Integrations::Medelement::AppointmentProviderStatus }
  let(:appointment) { create(:scheduling_appointment) }
  let(:command) do
    Integrations::Medelement::ProviderCommand.create!(
      account: appointment.account, appointment: appointment, contact: appointment.contact, operation: 'create_reception',
      status: 'succeeded', provider_reception_code: 'receipt-1', provider_patient_code: 'patient-1',
      company_cabinet_code: 'cabinet-1', idempotency_key: SecureRandom.uuid, executed_at: Time.current,
      execution_state: {
        'write_provider_reception_code' => 'receipt-1', 'request_fingerprint' => 'fp', 'dispatch_identity' => 'dispatch',
        verification::STATE_KEY => { 'status' => 'pending', 'attempts' => 0 }
      }
    )
  end

  before do
    appointment.mark_medelement_provider_reconciled!
    appointment.update!(external_ref: 'medelement:reception:receipt-1', custom_attributes: provider.command_attributes(command).merge(
      provider::ATTRIBUTE_KEY => provider::SUCCEEDED, 'medelement_reception_code' => 'receipt-1'
    ))
  end

  def reconcile(**options)
    described_class.new(appointment: appointment.reload, snapshot_version: appointment.updated_at, **options).perform
  end

  it 'does not count repeated empty snapshots before this acknowledged create materializes' do
    original = appointment.attributes

    3.times { expect(reconcile).to eq(:awaiting_provider_materialization) }

    expect(appointment.reload.attributes).to eq(original)
    expect(command.reload).to be_succeeded
    availability = Scheduling::AvailabilityService.new(
      resource: appointment.resource, from: appointment.starts_at, to: appointment.ends_at,
      holidays: [], workday_overrides: [], time_offs: [], appointments: [appointment],
      provider_working_windows: [[appointment.starts_at, appointment.ends_at]], replace_work_rules: true
    )
    expect(availability.availability_result(starts_at: appointment.starts_at, ends_at: appointment.ends_at).available?).to be(false)
  end

  it 'keeps the protection after unavailable reads exhaust their bounded budget' do
    command.update!(execution_state: command.execution_state.merge(verification::STATE_KEY => {
      'status' => 'pending', 'attempts' => verification::MAX_ATTEMPTS, 'reason' => 'provider_unavailable'
    }))

    3.times { expect(reconcile).to eq(:awaiting_provider_materialization) }

    expect(appointment.reload).to have_attributes(status: 'scheduled', payment_status: 'awaiting_payment')
    expect(appointment.custom_attributes).not_to include('medelement_missing_syncs', 'medelement_removed_at')
  end

  it 'uses the existing two-snapshot rule after exact read materialization' do
    command.update!(execution_state: command.execution_state.merge(verification::STATE_KEY => { 'status' => 'verified', 'attempts' => 1 }))

    reconcile
    expect(appointment.reload.custom_attributes['medelement_missing_syncs']).to eq(1)
    reconcile

    expect(appointment.reload.status).to eq('cancelled')
    expect(appointment.custom_attributes.dig('provider_status_audit', 'reason')).to eq('missing_from_two_authoritative_snapshots')
  end

  it 'does not give old read-confirmed successes the new pending receipt protection' do
    command.update!(execution_state: command.execution_state.except(verification::STATE_KEY))

    reconcile
    reconcile

    expect(appointment.reload.status).to eq('cancelled')
  end

  it 'does not apply another command or reception binding to this appointment' do
    appointment.mark_medelement_provider_reconciled!
    appointment.update!(custom_attributes: appointment.custom_attributes.merge(provider::COMMAND_FINGERPRINT_KEY => 'new-request'))

    expect(verification.unmaterialized_current_create?(appointment)).to be(false)
    appointment.update!(custom_attributes: appointment.custom_attributes.merge(provider::COMMAND_FINGERPRINT_KEY => 'fp'),
                        external_ref: 'medelement:reception:other-receipt')
    expect(verification.unmaterialized_current_create?(appointment)).to be(false)
  end

  it 'accepts an explicit authoritative provider removal without waiting for appearance' do
    reconcile(provider_removal_confirmed: true)

    expect(appointment.reload).to have_attributes(status: 'cancelled', payment_status: 'cancelled')
    expect(appointment.custom_attributes.dig('provider_status_audit', 'reason')).to eq('provider_removed')
    expect(Integrations::Medelement::LocalCancellation.provider_occupied?(appointment)).to be(false)
  end

  it 'requires the same patient and ID before a native import may record materialization' do
    expected = { verification::MATERIALIZED_COMMAND_KEY => command.id }
    expect(verification.materialization_attributes(appointment, 'RECEPTION_CODE' => 'receipt-1', 'PATIENT_CODE' => 'patient-1')).to eq(expected)
    expect(verification.materialization_attributes(appointment, 'RECEPTION_CODE' => 'receipt-1', 'PATIENT_CODE' => 'other-patient')).to eq({})
    expect(verification.materialization_attributes(appointment, 'RECEPTION_CODE' => 'other-receipt', 'PATIENT_CODE' => 'patient-1')).to eq({})
  end
end
