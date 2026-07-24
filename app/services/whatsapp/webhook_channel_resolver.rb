class Whatsapp::WebhookChannelResolver
  def initialize(params:)
    @params = params.with_indifferent_access
  end

  def perform
    return channel_from_metadata if routing_metadata.any?

    unique_waba_channel
  end

  def routing_context
    entry = Array(@params[:entry]).first.to_h.with_indifferent_access
    {
      business_account_id: entry[:id],
      metadata: routing_metadata.first.to_h
    }
  end

  def matches_routing_metadata?(channel)
    return false unless channel.present? && complete_routing_metadata? && metadata_pairs.one?

    metadata = routing_metadata.first
    metadata_matches_channel?(channel, metadata) && waba_matches_channel?(channel)
  end

  private

  def channel_from_metadata
    return unless complete_routing_metadata? && metadata_pairs.one?

    metadata = routing_metadata.first
    channel = Channel::Whatsapp.find_by(phone_number: normalized_phone_number(metadata))
    return unless channel&.provider == 'whatsapp_cloud' && matches_routing_metadata?(channel)

    channel if unambiguous_cloud_waba_ownership?(channel)
  end

  def complete_routing_metadata?
    return false if routing_metadata.empty?

    routing_metadata.all? do |value|
      value[:display_phone_number].present? && value[:phone_number_id].present?
    end
  end

  def metadata_matches_channel?(channel, metadata)
    channel.phone_number == normalized_phone_number(metadata) &&
      channel.provider_config.to_h['phone_number_id'].to_s == metadata[:phone_number_id].to_s
  end

  def waba_matches_channel?(channel)
    return true if waba_ids.empty?

    channel_waba_id = channel.provider_config.to_h['business_account_id'].to_s
    channel_waba_id.present? && waba_ids.all?(channel_waba_id)
  end

  def unambiguous_cloud_waba_ownership?(channel)
    return true if waba_ids.empty?

    Channel::Whatsapp.unambiguous_waba_owner_account_id(waba_ids) == channel.account_id
  end

  def metadata_pairs
    routing_metadata.map do |value|
      [value[:display_phone_number].to_s.delete_prefix('+'), value[:phone_number_id].to_s]
    end.uniq
  end

  def normalized_phone_number(metadata)
    "+#{metadata[:display_phone_number].to_s.delete_prefix('+')}"
  end

  def unique_waba_channel
    return if waba_ids.empty?

    owner_account_id = Channel::Whatsapp.unambiguous_waba_owner_account_id(waba_ids)
    return if owner_account_id.blank?

    channels = Channel::Whatsapp.active_cloud.for_waba(waba_ids).where(account_id: owner_account_id)
    coexistence_channels = channels.where("provider_config ->> 'embedded_signup_flow' = 'coexistence'").limit(2).to_a
    coexistence_channels.one? ? coexistence_channels.first : nil
  end

  def waba_ids
    @waba_ids ||= Array(@params[:entry]).filter_map { |entry| entry[:id] }.map(&:to_s).uniq
  end

  def routing_metadata
    @routing_metadata ||= Array(@params[:entry]).flat_map { |entry| Array(entry[:changes]) }
                                                .filter_map { |change| change.dig(:value, :metadata).presence }
  end
end
