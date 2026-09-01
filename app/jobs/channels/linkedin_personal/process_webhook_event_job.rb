# Compatibility tombstone for jobs enqueued before LinkedIn Personal was retired.
# Remove this class in the contract release after the queue has been verified empty.
class Channels::LinkedinPersonal::ProcessWebhookEventJob < ApplicationJob
  queue_as :high

  def perform(*)
    Rails.logger.info('[LINKEDIN PERSONAL] discarded retired webhook job')
  end
end
