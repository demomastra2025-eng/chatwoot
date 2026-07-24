module WhatsappChannelRouting
  extend ActiveSupport::Concern

  included do
    attr_accessor :skip_waba_routing_ownership_validation, :skip_webhook_teardown

    scope :cloud, -> { where(provider: 'whatsapp_cloud') }
    scope :lifecycle_cloud, -> { cloud }
    scope :waba_ownership_cloud, -> { lifecycle_cloud.joins(:account).merge(Account.active) }
    scope :active_cloud, -> { lifecycle_cloud.joins(:account, :inbox).merge(Account.active).merge(Inbox.active) }
    scope :for_waba, ->(waba_ids) { where("provider_config ->> 'business_account_id' IN (?)", Array(waba_ids).map(&:to_s)) }
  end

  class_methods do
    def unambiguous_waba_owner_account_id(waba_ids)
      account_ids = waba_ownership_cloud.for_waba(waba_ids).distinct.limit(2).pluck(:account_id)
      account_ids.first if account_ids.one?
    end
  end

  def callback_webhook_url
    base_url = "#{ENV.fetch('FRONTEND_URL', nil)}/webhooks/whatsapp"
    return "#{base_url}/#{phone_number}" unless provider == 'whatsapp_cloud'
    return base_url unless manual_webhook_callback?

    "#{base_url}?channel_id=#{id}"
  end

  def manual_webhook_callback?
    provider == 'whatsapp_cloud' && provider_config.to_h['source'] != 'embedded_signup'
  end
end
