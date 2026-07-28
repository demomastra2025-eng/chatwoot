class Integrations::Medelement::ProviderCommandDispatcherJob < ApplicationJob
  queue_as :scheduled_jobs

  BATCH_SIZE = 200
  STALE_PROCESSING_AGE = 15.minutes

  def perform
    mark_stale_processing_commands!
    dispatch_resolved_confirmations
    dispatch_queued_commands
    dispatch_reconciliation_commands
  end

  private

  def mark_stale_processing_commands!
    stale_commands = Integrations::Medelement::ProviderCommand.processing.where(updated_at: ...STALE_PROCESSING_AGE.ago)

    # Each conditional update is atomic. Once one dispatcher changes the status, competing runs no longer match it.
    # A command that crashed before recording a write phase is safe to retry; a started write must be reconciled.
    # rubocop:disable Rails/SkipsModelValidations
    stale_commands
      .where("NULLIF(execution_state ->> 'write_phase', '') IS NULL")
      .update_all(
        status: 'queued',
        last_error_code: 'executor_stale_before_write',
        last_error_status: nil,
        updated_at: Time.current
      )
    stale_commands
      .where("NULLIF(execution_state ->> 'write_phase', '') IS NOT NULL")
      .update_all(
        status: 'reconciliation_required',
        last_error_code: 'executor_stale',
        last_error_status: nil,
        updated_at: Time.current
      )
    # rubocop:enable Rails/SkipsModelValidations
  end

  def dispatch_resolved_confirmations
    Integrations::Medelement::ProviderCommand
      .awaiting_confirmation
      .joins(:confirmation_request)
      .where(
        'confirmation_requests.status <> :pending OR confirmation_requests.expires_at <= :now',
        pending: 'pending',
        now: Time.current
      )
      .limit(BATCH_SIZE)
      .pluck(:confirmation_request_id)
      .each { |id| Integrations::Medelement::ProviderCommandConfirmationJob.perform_later(id) }
  end

  def dispatch_queued_commands
    Integrations::Medelement::ProviderCommand
      .queued
      .limit(BATCH_SIZE)
      .pluck(:id)
      .each { |id| Integrations::Medelement::ProviderCommandJob.perform_later(id) }
  end

  def dispatch_reconciliation_commands
    Integrations::Medelement::ProviderCommand
      .reconciliation_required
      .limit(BATCH_SIZE)
      .pluck(:id)
      .each { |id| Integrations::Medelement::ProviderCommandReconciliationJob.perform_later(id) }
  end
end
