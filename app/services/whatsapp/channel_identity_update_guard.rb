class Whatsapp::ChannelIdentityUpdateGuard
  IDENTITY_CONFIG_KEYS = %w[business_account_id business_id embedded_signup_flow phone_number_id source].freeze

  def initialize(channel)
    @channel = channel
  end

  def validate!(channel_params)
    return channel_params unless @channel.is_a?(Channel::Whatsapp)

    attributes = channel_params.to_h.with_indifferent_access
    target_provider = attributes[:provider].presence || @channel.provider
    return channel_params unless [@channel.provider, target_provider].include?('whatsapp_cloud')

    changed_keys = changed_identity_keys(attributes)
    return channel_params if changed_keys.empty?

    @channel.errors.add(
      :provider_config,
      "identity fields require the WhatsApp reauthorization flow: #{changed_keys.join(', ')}"
    )
    raise ActiveRecord::RecordInvalid, @channel
  end

  private

  def changed_identity_keys(attributes)
    changed_keys = changed_provider_config_keys(attributes[:provider_config].to_h.deep_stringify_keys)
    changed_keys << 'provider' if attributes.key?(:provider) && attributes[:provider].to_s != @channel.provider.to_s
    changed_keys << 'phone_number' if phone_number_changed?(attributes[:phone_number])
    changed_keys
  end

  def changed_provider_config_keys(incoming_config)
    current_config = @channel.provider_config.to_h
    IDENTITY_CONFIG_KEYS.select do |key|
      incoming_config.key?(key) && incoming_config[key].to_s != current_config[key].to_s
    end
  end

  def phone_number_changed?(phone_number)
    phone_number.present? && phone_number.to_s != @channel.phone_number.to_s
  end
end
