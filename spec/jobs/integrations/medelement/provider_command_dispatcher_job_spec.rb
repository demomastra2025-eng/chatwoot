require 'rails_helper'

RSpec.describe Integrations::Medelement::ProviderCommandDispatcherJob do
  let(:account) { create(:account) }
  let(:contact) { create(:contact, account: account) }
  let(:hook) { create(:integrations_hook, :medelement, account: account) }

  before do
    account.enable_features!('scheduling')
    schedule_service = instance_double(Integrations::Medelement::CronScheduleService, sync!: true)
    allow(Integrations::Medelement::CronScheduleService).to receive(:new).and_return(schedule_service)
    allow(Integrations::Medelement::ProviderCommandConfirmationJob).to receive(:perform_later)
    allow(Integrations::Medelement::ProviderCommandJob).to receive(:perform_later)
    allow(Integrations::Medelement::ProviderCommandReconciliationJob).to receive(:perform_later)
  end

  it 'dispatches resolved confirmations, queued commands, reconciliation, and marks stale processing' do
    confirmed_request = create(
      :confirmation_request,
      account: account,
      conversation: nil,
      contact: contact,
      status: 'confirmed',
      resolved_at: Time.current
    )
    awaiting = create_command(status: 'awaiting_confirmation', confirmation_request: confirmed_request)
    queued = create_command(status: 'queued')
    reconciliation = create_command(status: 'reconciliation_required')
    stale = create_command(status: 'processing', execution_state: { 'write_phase' => 'patient_create' })
    stale.update!(updated_at: 20.minutes.ago)

    described_class.perform_now

    expect(Integrations::Medelement::ProviderCommandConfirmationJob)
      .to have_received(:perform_later).with(awaiting.confirmation_request_id)
    expect(Integrations::Medelement::ProviderCommandJob).to have_received(:perform_later).with(queued.id)
    expect(Integrations::Medelement::ProviderCommandReconciliationJob).to have_received(:perform_later).with(reconciliation.id)
    expect(Integrations::Medelement::ProviderCommandReconciliationJob).to have_received(:perform_later).with(stale.id)
    expect(stale.reload).to have_attributes(status: 'reconciliation_required', last_error_code: 'executor_stale')
  end

  it 'requeues stale processing that crashed before recording a write phase' do
    stale = create_command(status: 'processing')
    stale.update!(updated_at: 20.minutes.ago)

    described_class.perform_now

    expect(Integrations::Medelement::ProviderCommandJob).to have_received(:perform_later).with(stale.id)
    expect(Integrations::Medelement::ProviderCommandReconciliationJob).not_to have_received(:perform_later).with(stale.id)
    expect(stale.reload).to have_attributes(status: 'queued', last_error_code: 'executor_stale_before_write')
  end

  private

  def create_command(status:, confirmation_request: nil, execution_state: {})
    Integrations::Medelement::ProviderCommand.create!(
      account: account,
      hook: hook,
      contact: confirmation_request&.contact || create(:contact, account: account),
      confirmation_request: confirmation_request,
      operation: 'create_patient',
      status: status,
      execution_state: execution_state,
      idempotency_key: SecureRandom.uuid
    )
  end
end
