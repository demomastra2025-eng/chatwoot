# frozen_string_literal: true

# The pending flag commits with the provider acknowledgement. Both the after-commit fast
# path and the scheduled recovery use this same reconciler; Redis enqueue is not required.
class Accounts::AiUsageOutbox
  def self.stage!(message)
    fresh = Message.find(message.id)
    return if fresh.failed? || !acknowledged?(fresh)

    fresh.update_columns(ai_usage_pending: true, ai_usage_sent_at: fresh.ai_usage_sent_at || Time.current, ai_usage_retry_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
  end

  def self.deliver(message_id)
    return false unless Accounts::AiUsageRollout.active?

    Message.transaction(requires_new: true) do
      message = Message.lock('FOR UPDATE SKIP LOCKED').find_by(id: message_id)
      next false unless message&.ai_usage_pending?

      Accounts::MonthlyAiUsageService.new(message.account).record_sent_message!(message)
      message.update_columns(ai_usage_pending: false) # rubocop:disable Rails/SkipsModelValidations
      true
    end
  rescue StandardError => e
    # Pending remains durable after rollback; recovery does not call an outbound provider.
    defer_retry(message_id)
    Rails.logger.warn("[AI USAGE] pending message_id=#{message_id} error_class=#{e.class.name}")
    false
  end

  def self.defer_retry(message_id)
    Message.where(id: message_id, ai_usage_pending: true).update_all(ai_usage_retry_at: 1.minute.from_now) # rubocop:disable Rails/SkipsModelValidations
  rescue StandardError
    # The original pending row is sufficient for recovery when the database returns.
    nil
  end
  private_class_method :defer_retry

  def self.acknowledged?(message)
    message.source_id.present? || message.delivered? || message.read? ||
      message.inbox.channel_type.in?(%w[Channel::WebWidget Channel::Api])
  end
  private_class_method :acknowledged?
end
