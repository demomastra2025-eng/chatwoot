class Integrations::Medelement::ProviderCommandDispatcherJob < ApplicationJob
  queue_as :medelement_provider_commands

  BATCH_SIZE = 200
  STALE_PROCESSING_AGE = 15.minutes

  def perform
    mark_stale_processing_commands!
    mark_exhausted_reconciliation_commands!
    dispatch_resolved_confirmations
    dispatch_queued_commands
    dispatch_reconciliation_commands
  end

  private

  def mark_stale_processing_commands!
    stale_commands = Integrations::Medelement::ProviderCommand.where(
      status: Integrations::Medelement::ProviderCommand.execution_statuses('processing'),
      updated_at: ...STALE_PROCESSING_AGE.ago
    )

    # Each conditional update is atomic. Once one dispatcher changes the status, competing runs no longer match it.
    # A command that crashed before recording a write phase is safe to retry; a started write must be reconciled.
    transition_stale_commands!(
      stale_commands.where("NULLIF(execution_state ->> 'write_phase', '') IS NULL"),
      to: 'queued',
      error_code: 'executor_stale_before_write'
    )
    transition_stale_commands!(
      stale_commands.where("NULLIF(execution_state ->> 'write_phase', '') IS NOT NULL"),
      to: 'reconciliation_required',
      error_code: 'executor_stale'
    )
  end

  def dispatch_resolved_confirmations
    Integrations::Medelement::ProviderCommand
      .where(status: Integrations::Medelement::ProviderCommand.execution_statuses('awaiting_confirmation'))
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
      .where(status: Integrations::Medelement::ProviderCommand.execution_statuses('queued'))
      .limit(BATCH_SIZE)
      .pluck(:id)
      .each { |id| Integrations::Medelement::ProviderCommandJob.perform_later(id) }
  end

  def dispatch_reconciliation_commands
    Integrations::Medelement::ProviderCommand
      .where(status: Integrations::Medelement::ProviderCommand.execution_statuses('reconciliation_required'))
      .where(
        "COALESCE((execution_state ->> 'reconciliation_attempts')::integer, 0) < ?",
        Integrations::Medelement::ProviderCommand::RECONCILIATION_MAX_ATTEMPTS
      )
      .where(
        "NULLIF(execution_state ->> 'reconciliation_next_at', '') IS NULL OR " \
        "(execution_state ->> 'reconciliation_next_at')::timestamptz <= ?",
        Time.current
      )
      .limit(BATCH_SIZE)
      .pluck(:id)
      .each { |id| Integrations::Medelement::ProviderCommandReconciliationJob.perform_later(id) }
  end

  def mark_exhausted_reconciliation_commands!
    # rubocop:disable Rails/SkipsModelValidations
    Integrations::Medelement::ProviderCommand
      .where(status: Integrations::Medelement::ProviderCommand.execution_statuses('reconciliation_required'))
      .where(
        "COALESCE((execution_state ->> 'reconciliation_attempts')::integer, 0) >= ?",
        Integrations::Medelement::ProviderCommand::RECONCILIATION_MAX_ATTEMPTS
      )
      .update_all(
        status: 'failed',
        last_error_code: 'reconciliation_exhausted',
        updated_at: Time.current
      )
    # rubocop:enable Rails/SkipsModelValidations
  end

  def transition_stale_commands!(commands, to:, error_code:)
    source_statuses = Integrations::Medelement::ProviderCommand.execution_statuses('processing')
    target_statuses = Integrations::Medelement::ProviderCommand.execution_statuses(to)
    source_statuses.zip(target_statuses).each do |source_status, target_status|
      # rubocop:disable Rails/SkipsModelValidations
      commands.where(status: source_status).update_all(
        status: target_status,
        last_error_code: error_code,
        last_error_status: nil,
        updated_at: Time.current
      )
      # rubocop:enable Rails/SkipsModelValidations
    end
  end
end
