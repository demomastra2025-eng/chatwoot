# frozen_string_literal: true

class Llm::Monitoring::RetentionEnforcer
  ACCOUNT_BATCH_SIZE = 100
  EVENT_BATCH_SIZE = 1_000

  def initialize(account_scope: Account.all, event_scope: LlmEvent.all, now: Time.current)
    @account_scope = account_scope
    @event_scope = event_scope
    @now = now
  end

  def call
    summary = {
      processed_accounts: 0,
      deleted_events: 0,
      deleted_annotations: 0
    }

    @account_scope.find_in_batches(batch_size: ACCOUNT_BATCH_SIZE) do |accounts|
      accounts.each do |account|
        counts = purge_scope(
          @event_scope.where(account_id: account.id).where('created_at < ?', cutoff_for(account))
        )
        summary[:processed_accounts] += 1
        summary[:deleted_events] += counts[:events]
        summary[:deleted_annotations] += counts[:annotations]
      end
    end

    global_counts = purge_scope(
      @event_scope.where(account_id: nil).where('created_at < ?', @now - Llm::Monitoring::AccountPreferences::DEFAULT_RETENTION_DAYS.days)
    )

    summary[:deleted_events] += global_counts[:events]
    summary[:deleted_annotations] += global_counts[:annotations]
    summary
  end

  private

  def cutoff_for(account)
    retention_days = Llm::Monitoring::AccountPreferences.for(account).fetch(
      'retention_days',
      Llm::Monitoring::AccountPreferences::DEFAULT_RETENTION_DAYS
    )
    @now - retention_days.days
  end

  def purge_scope(scope)
    deleted_events = 0
    deleted_annotations = 0

    scope.in_batches(of: EVENT_BATCH_SIZE) do |relation|
      ids = relation.pluck(:id)
      next if ids.blank?

      deleted_annotations += LlmEventAnnotation.where(llm_event_id: ids).delete_all
      deleted_events += LlmEvent.where(id: ids).delete_all
    end

    {
      events: deleted_events,
      annotations: deleted_annotations
    }
  end
end
