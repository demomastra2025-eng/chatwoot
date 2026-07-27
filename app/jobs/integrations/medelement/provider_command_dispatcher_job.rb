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
    # A single atomic update is required so competing dispatcher runs cannot recover the same stale command twice.
    Integrations::Medelement::ProviderCommand
      .processing
      .where(updated_at: ...STALE_PROCESSING_AGE.ago)
      # rubocop:disable Rails/SkipsModelValidations
      .update_all(
        status: 'reconciliation_required',
        last_error_code: 'executor_stale',
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
