# Compatibility tombstone for jobs enqueued before the AgentBot runtime was retired.
# Remove this class in the contract release after the queue has been verified empty.
class AgentBots::WebhookJob < ApplicationJob
  queue_as :medium

  def perform(*)
    Rails.logger.info('[AgentBots::WebhookJob] discarded retired AgentBot webhook job')
  end
end
