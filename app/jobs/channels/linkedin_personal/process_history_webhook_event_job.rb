# Compatibility tombstone for jobs enqueued before LinkedIn Personal was retired.
# Remove this class in the contract release after the queue has been verified empty.
class Channels::LinkedinPersonal::ProcessHistoryWebhookEventJob < ApplicationJob
  queue_as :linkedin_personal_history

  def perform(*)
    Rails.logger.info('[LINKEDIN PERSONAL] discarded retired history webhook job')
  end
end
