# Commands are started the moment their confirmation resolves (ProviderCommandConfirmationJob.dispatch) and executed from
# the queue right away. This minute job is only the recovery net: it picks up a command whose start was lost (a process
# died between the commit and the enqueue, the queue dropped the job) and runs the due reconciliations. It leaves a
# command alone while the normal path can still be carrying it, so it never doubles that path.
class Integrations::Medelement::ProviderCommandDispatcherJob < ApplicationJob
  queue_as :medelement_provider_commands

  BATCH_SIZE = 200
  STALE_PROCESSING_AGE = 15.minutes
  RECOVERY_AGE = 30.seconds

  def perform
    requeued_ids = mark_stale_processing_commands!
    mark_exhausted_reconciliation_commands_unknown!
    dispatch_resolved_confirmations
    dispatch_queued_commands(requeued_ids)
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
    requeued_ids = transition_stale_commands!(
      stale_commands.where("NULLIF(execution_state ->> 'write_phase', '') IS NULL"),
      to: 'queued',
      error_code: 'executor_stale_before_write'
    )
    transition_stale_commands!(
      stale_commands.where("NULLIF(execution_state ->> 'write_phase', '') IS NOT NULL"),
      to: 'reconciliation_required',
      error_code: 'executor_stale'
    )
    requeued_ids
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
      .where('confirmation_requests.resolved_at IS NULL OR confirmation_requests.resolved_at <= ?', RECOVERY_AGE.ago)
      .limit(BATCH_SIZE)
      .pluck(:confirmation_request_id)
      .each { |id| Integrations::Medelement::ProviderCommandConfirmationJob.perform_later(id) }
  end

  # A command that the stale-processing recovery just put back is started at once; the others only after RECOVERY_AGE.
  def dispatch_queued_commands(requeued_ids = [])
    ids = Integrations::Medelement::ProviderCommand
          .where(status: Integrations::Medelement::ProviderCommand.execution_statuses('queued'))
          .where(updated_at: ...RECOVERY_AGE.ago)
          .limit(BATCH_SIZE)
          .pluck(:id)
    (ids | requeued_ids).each { |id| Integrations::Medelement::ProviderCommandJob.perform_later(id) }
  end

  def dispatch_reconciliation_commands
    reconciliation_ids = due_reconciliation_scope('reconciliation_required').limit(BATCH_SIZE).pluck(:id)
    reconciliation_ids.each { |id| Integrations::Medelement::ProviderCommandReconciliationJob.perform_later(id) }

    remaining = BATCH_SIZE - reconciliation_ids.size
    return if remaining.zero?

    due_reconciliation_scope('provider_status_unknown').limit(remaining).pluck(:id).each do |id|
      command = Integrations::Medelement::ProviderCommand.find_by(id: id)
      next if command.blank?
      next unless Integrations::Medelement::ProviderCommands::ReconciliationLifecycle.new(
        command: command
      ).reserve_unknown_dispatch!

      Integrations::Medelement::ProviderCommandReconciliationJob.perform_later(id)
    end
  end

  def due_reconciliation_scope(logical_status)
    Integrations::Medelement::ProviderCommand
      .where(status: Integrations::Medelement::ProviderCommand.execution_statuses(logical_status))
      .where(
        "NULLIF(execution_state ->> 'reconciliation_next_at', '') IS NULL OR " \
        "(execution_state ->> 'reconciliation_next_at')::timestamptz <= ?",
        Time.current
      )
  end

  def mark_exhausted_reconciliation_commands_unknown!
    Integrations::Medelement::ProviderCommand
      .where(status: Integrations::Medelement::ProviderCommand.execution_statuses('reconciliation_required'))
      .where(
        "COALESCE((execution_state ->> 'reconciliation_attempts')::integer, 0) >= ?",
        Integrations::Medelement::ProviderCommand::RECONCILIATION_MAX_ATTEMPTS
      )
      .find_each do |command|
        Integrations::Medelement::ProviderCommands::ReconciliationLifecycle.new(command: command).mark_unknown_if_exhausted!
      end
  end

  def transition_stale_commands!(commands, to:, error_code:)
    source_statuses = Integrations::Medelement::ProviderCommand.execution_statuses('processing')
    target_statuses = Integrations::Medelement::ProviderCommand.execution_statuses(to)
    source_statuses.zip(target_statuses).flat_map do |source_status, target_status|
      scope = commands.where(status: source_status)
      ids = scope.pluck(:id)
      # rubocop:disable Rails/SkipsModelValidations
      scope.update_all(
        status: target_status,
        last_error_code: error_code,
        last_error_status: nil,
        updated_at: Time.current
      )
      # rubocop:enable Rails/SkipsModelValidations
      ids
    end
  end
end
