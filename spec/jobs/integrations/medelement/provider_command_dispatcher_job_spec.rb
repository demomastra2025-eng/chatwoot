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

  it 'dispatches resolved confirmations, queued commands, reconciliation, and marks stale processing', :aggregate_failures do
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
    future_reconciliation = create_command(
      status: 'reconciliation_required',
      execution_state: { 'reconciliation_next_at' => 10.minutes.from_now.iso8601 }
    )
    exhausted_reconciliation = create_command(
      status: 'reconciliation_required',
      execution_state: {
        'reconciliation_attempts' => Integrations::Medelement::ProviderCommand::RECONCILIATION_MAX_ATTEMPTS
      }
    )
    stale = create_command(status: 'processing', execution_state: { 'write_phase' => 'patient_create' })
    stale.update!(updated_at: 20.minutes.ago)

    described_class.perform_now

    expect(Integrations::Medelement::ProviderCommandConfirmationJob)
      .to have_received(:perform_later).with(awaiting.confirmation_request_id)
    expect(Integrations::Medelement::ProviderCommandJob).to have_received(:perform_later).with(queued.id)
    expect(Integrations::Medelement::ProviderCommandReconciliationJob).to have_received(:perform_later).with(reconciliation.id)
    expect(Integrations::Medelement::ProviderCommandReconciliationJob).to have_received(:perform_later).with(stale.id)
    expect(Integrations::Medelement::ProviderCommandReconciliationJob)
      .not_to have_received(:perform_later).with(future_reconciliation.id)
    expect(Integrations::Medelement::ProviderCommandReconciliationJob)
      .not_to have_received(:perform_later).with(exhausted_reconciliation.id)
    expect(stale.reload).to have_attributes(status: 'reconciliation_required', last_error_code: 'executor_stale')
    expect(exhausted_reconciliation.reload).to have_attributes(
      status: 'provider_status_unknown',
      last_error_code: 'provider_status_unknown'
    )
    expect(exhausted_reconciliation.reconciliation_next_at).to be > 23.hours.from_now
  end

  it 'reserves unknown reconciliation before enqueueing it' do
    unknown_reconciliation = create_command(
      status: 'provider_status_unknown',
      execution_state: {
        'write_phase' => 'patient_create',
        'reconciliation_attempts' => Integrations::Medelement::ProviderCommand::RECONCILIATION_MAX_ATTEMPTS,
        'reconciliation_next_at' => 1.minute.ago.iso8601
      }
    )

    described_class.perform_now
    described_class.perform_now

    expect(Integrations::Medelement::ProviderCommandReconciliationJob)
      .to have_received(:perform_later).with(unknown_reconciliation.id).once
    expect(unknown_reconciliation.reload.reconciliation_next_at).to be > 23.hours.from_now
  end

  it 'requeues stale processing that crashed before recording a write phase' do
    stale = create_command(status: 'processing')
    stale.update!(updated_at: 20.minutes.ago)

    described_class.perform_now

    expect(Integrations::Medelement::ProviderCommandJob).to have_received(:perform_later).with(stale.id)
    expect(Integrations::Medelement::ProviderCommandReconciliationJob).not_to have_received(:perform_later).with(stale.id)
    expect(stale.reload).to have_attributes(status: 'queued', last_error_code: 'executor_stale_before_write')
  end

  it 'dispatches versioned commands that remain invisible to legacy exact-status queries', :aggregate_failures do
    confirmed_request = create(
      :confirmation_request,
      account: account,
      conversation: nil,
      contact: contact,
      status: 'confirmed',
      resolved_at: Time.current
    )
    awaiting = create_command(status: 'v2_awaiting_confirmation', confirmation_request: confirmed_request)
    queued = create_command(status: 'v2_queued')
    reconciliation = create_command(status: 'v2_reconciliation_required')
    stale_before_write = create_command(status: 'v2_processing')
    stale_after_write = create_command(status: 'v2_processing', execution_state: { 'write_phase' => 'patient_create' })
    [stale_before_write, stale_after_write].each { |command| command.update!(updated_at: 20.minutes.ago) }

    expect(Integrations::Medelement::ProviderCommand.where(status: 'awaiting_confirmation')).not_to include(awaiting)
    expect(Integrations::Medelement::ProviderCommand.where(status: 'queued')).not_to include(queued)
    expect(Integrations::Medelement::ProviderCommand.where(status: 'reconciliation_required')).not_to include(reconciliation)

    described_class.perform_now

    expect(Integrations::Medelement::ProviderCommandConfirmationJob)
      .to have_received(:perform_later).with(awaiting.confirmation_request_id)
    expect(Integrations::Medelement::ProviderCommandJob).to have_received(:perform_later).with(queued.id)
    expect(Integrations::Medelement::ProviderCommandJob).to have_received(:perform_later).with(stale_before_write.id)
    expect(Integrations::Medelement::ProviderCommandReconciliationJob).to have_received(:perform_later).with(reconciliation.id)
    expect(Integrations::Medelement::ProviderCommandReconciliationJob).to have_received(:perform_later).with(stale_after_write.id)
    expect(stale_before_write.reload).to have_attributes(
      status: 'v2_queued',
      last_error_code: 'executor_stale_before_write'
    )
    expect(stale_after_write.reload).to have_attributes(
      status: 'v2_reconciliation_required',
      last_error_code: 'executor_stale'
    )
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
