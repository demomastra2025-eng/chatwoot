module Enterprise::Concerns::Portal
  extend ActiveSupport::Concern
  include AccountStorageLimitable

  included do
    account_storage_attachments :logo
    after_save :enqueue_cloudflare_verification, if: :saved_change_to_custom_domain?
  end

  def enqueue_cloudflare_verification
    return if custom_domain.blank?
    return unless ChatwootApp.chatwoot_cloud?

    Enterprise::CloudflareVerificationJob.perform_later(id)
  end
end
