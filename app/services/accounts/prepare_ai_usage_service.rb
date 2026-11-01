# frozen_string_literal: true

# Retry-safe history preparation, intentionally outside the messages DDL transaction.
# Every batch holds only the rollout cursor row; source messages are read without row locks.
class Accounts::PrepareAiUsageService
  BATCH_SIZE = 1000

  def initialize(batch_size: BATCH_SIZE)
    @batch_size = batch_size
    @rollout = Accounts::AiUsageRollout.current
  end

  def perform
    snapshot!
    loop do
      done = prepare_batch!
      break if done
    end
    @rollout.reload
  end

  private

  def snapshot!
    @rollout.with_lock do
      @rollout.update!(cutoff_message_id: Message.maximum(:id).to_i) if @rollout.cutoff_message_id.nil?
    end
  end

  def prepare_batch!
    @rollout.with_lock do
      next true if @rollout.prepared_at

      ids = Message.where(id: (@rollout.cursor + 1)..@rollout.cutoff_message_id).reorder(:id).limit(@batch_size).pluck(:id)
      seed_sources!(ids) if ids.any?
      cursor = ids.last || @rollout.cutoff_message_id
      done = cursor >= @rollout.cutoff_message_id
      @rollout.update!(cursor: cursor, prepared_at: (Time.current if done))
      done
    end
  end

  def seed_sources!(ids)
    # Old human sends are also historical: later replayed AI feedback must never retrocharge them.
    rows = Message.where(id: ids, message_type: :outgoing, private: false, ai_usage_version: nil)
                  .where(account_id: Account.select(:id)).where.not(status: :failed)
                  .where("NULLIF(source_id, '') IS NOT NULL OR status IN (1, 2) OR " \
                         "inbox_id IN (SELECT id FROM inboxes WHERE channel_type IN ('Channel::Api', 'Channel::WebWidget'))")
                  .pluck(:id, :account_id, :created_at)
    events = rows.map do |id, account_id, at|
      { account_id: account_id, event_key: "message:#{id}", bucket: Accounts::MonthlyAiUsageService::AI_DIALOGS_MONTHLY_KEY,
        occurred_at: at, quantity: 0 }
    end
    Accounts::AiUsageEvent.insert_all(events, unique_by: [:account_id, :event_key]) if events.any? # rubocop:disable Rails/SkipsModelValidations
  end
end
