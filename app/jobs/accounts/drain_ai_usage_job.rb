class Accounts::DrainAiUsageJob < ApplicationJob
  queue_as :scheduled_jobs
  BATCH_SIZE = 200

  def perform
    return unless Accounts::AiUsageRollout.active?

    Message.where(ai_usage_pending: true).where('ai_usage_retry_at <= ?', Time.current)
           .order(:ai_usage_retry_at, :id).limit(BATCH_SIZE).pluck(:id).each do |id|
      Accounts::AiUsageOutbox.deliver(id)
    end
  end
end
