# frozen_string_literal: true

class Internal::EnforceLlmEventRetentionJob < ApplicationJob
  queue_as :scheduled_jobs

  OPERATIONAL_LOG_RETENTION = 30.days
  BATCH_SIZE = 1_000

  def perform
    summary = Llm::Monitoring::RetentionEnforcer.new.call
    operational_summary = purge_operational_logs
    Rails.logger.info("[Internal::EnforceLlmEventRetentionJob] #{summary.merge(operational_summary)}")
  end

  private

  def purge_operational_logs
    cutoff = OPERATIONAL_LOG_RETENTION.ago
    {
      deleted_assignment_decision_logs: purge_in_batches(AssignmentDecisionLog.where('created_at < ?', cutoff)),
      deleted_processed_telephony_events: purge_in_batches(Telephony::Event.where(status: 'processed').where('created_at < ?', cutoff)),
      deleted_noisy_audits: purge_in_batches(Audited::Audit.where(action: %w[captain_tool_execute sign_in]).where('created_at < ?', cutoff))
    }
  rescue StandardError => e
    Rails.logger.warn("[Internal::EnforceLlmEventRetentionJob] Operational log purge warning: #{e.class}: #{e.message}")
    {}
  end

  def purge_in_batches(scope)
    scope.in_batches(of: BATCH_SIZE).delete_all
  end
end
