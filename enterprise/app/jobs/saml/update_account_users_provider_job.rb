# Compatibility tombstone for jobs enqueued before SAML was retired.
# Remove this class in the contract release after the queue has been verified empty.
class Saml::UpdateAccountUsersProviderJob < ApplicationJob
  queue_as :default

  def perform(*)
    Rails.logger.info('[SAML] discarded retired account user provider update job')
  end
end
