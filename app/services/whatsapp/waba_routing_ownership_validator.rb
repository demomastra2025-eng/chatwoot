class Whatsapp::WabaRoutingOwnershipValidator
  def initialize(channel)
    @channel = channel
  end

  def validate
    return unless applicable?

    if sibling_channels.where.not(account_id: @channel.account_id).exists?
      @channel.errors.add(:provider_config, :invalid)
    elsif duplicate_coexistence_channel?
      @channel.errors.add(:provider_config, :taken)
    end
  end

  private

  def applicable?
    @channel.provider == 'whatsapp_cloud' && @channel.account_id.present? && waba_id.present?
  end

  def duplicate_coexistence_channel?
    return false unless @channel.provider_config.to_h['embedded_signup_flow'] == 'coexistence'

    sibling_channels.where("provider_config ->> 'embedded_signup_flow' = 'coexistence'").exists?
  end

  def sibling_channels
    @sibling_channels ||= Channel::Whatsapp.lifecycle_cloud
                                           .where.not(id: @channel.id)
                                           .for_waba(waba_id)
  end

  def waba_id
    @waba_id ||= @channel.provider_config.to_h['business_account_id'].to_s
  end
end
