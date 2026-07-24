class Whatsapp::AccountUpdateChannelResolver
  def initialize(waba_ids:)
    @waba_ids = Array(waba_ids).map(&:to_s).uniq
  end

  def resolve
    safe_waba_ids = @waba_ids.reject { |waba_id| ambiguous_ownership?(waba_id) }
    whatsapp_cloud_channels.where("provider_config ->> 'business_account_id' IN (?)", safe_waba_ids)
  end

  private

  def ambiguous_ownership?(waba_id)
    account_ids = Channel::Whatsapp.waba_ownership_cloud.for_waba(waba_id).distinct.limit(2).pluck(:account_id)
    return false if account_ids.size <= 1

    Rails.logger.error('[WHATSAPP ACCOUNT UPDATE] refused event because WABA ownership spans multiple accounts')
    true
  end

  def whatsapp_cloud_channels
    Channel::Whatsapp.joins(:account, :inbox)
                     .merge(Account.active)
                     .merge(Inbox.active)
                     .where(provider: 'whatsapp_cloud')
  end
end
