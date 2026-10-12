class Integrations::Medelement::ProviderCommandConfirmationJob < ApplicationJob
  queue_as :medelement_provider_commands

  # A resolved confirmation starts its command at once, right after the transaction that resolved it commits: the
  # command is released and handed to the execution queue on the calling thread (a few quick database writes), so
  # nothing waits for a queue turn or for the recovery dispatcher. A failure here only falls back to the queue.
  def self.dispatch(confirmation_request_id)
    ActiveRecord.after_all_transactions_commit do
      perform_now(confirmation_request_id)
    rescue StandardError => e
      Rails.logger.warn("[MEDELEMENT::CONFIRMATION] immediate dispatch failed error=#{e.class.name}")
      perform_later(confirmation_request_id)
    end
  end

  def perform(confirmation_request_id)
    confirmation_request = ConfirmationRequest.find_by(id: confirmation_request_id)
    return if confirmation_request.blank?

    expire_confirmation!(confirmation_request)

    command = Integrations::Medelement::ProviderCommand.find_by(confirmation_request: confirmation_request)
    return if command.blank?

    should_enqueue = command.with_lock do
      resolve_command(command, confirmation_request)
      command.queued?
    end
    Integrations::Medelement::ProviderCommandJob.perform_later(command.id) if should_enqueue
  end

  private

  def expire_confirmation!(confirmation_request)
    confirmation_request.with_lock do
      next unless confirmation_request.pending? && confirmation_request.expires_at <= Time.current

      confirmation_request.update!(
        status: 'expired',
        resolved_at: Time.current,
        resolution_source: 'system',
        resolution_metadata: confirmation_request.resolution_metadata.to_h.merge('reason' => 'expired')
      )
    end
  end

  def resolve_command(command, confirmation_request)
    return unless command.awaiting_confirmation?

    case confirmation_request.status
    when 'confirmed'
      return fail_confirmation_binding!(command) unless command.confirmation_matches_request_snapshot?(confirmation_request)

      command.update!(
        status: command.status_for_transition('queued'),
        confirmed_at: confirmation_request.resolved_at || Time.current
      )
    when 'declined', 'reschedule_requested', 'expired'
      command.update!(status: 'declined', executed_at: Time.current)
    end
  end

  def fail_confirmation_binding!(command)
    command.update!(
      status: 'failed',
      executed_at: Time.current,
      last_error_code: 'confirmation_snapshot_invalid'
    )
  end
end
