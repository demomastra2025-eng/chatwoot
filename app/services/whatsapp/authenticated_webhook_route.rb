class Whatsapp::AuthenticatedWebhookRoute
  def self.identity_snapshot(channel, route_phone)
    return {} if channel.blank?

    config = channel.provider_config.to_h
    {
      account_id: channel.account_id,
      provider: channel.provider,
      waba_id: config['business_account_id'].to_s,
      phone_number_id: config['phone_number_id'].to_s,
      route_phone: (route_phone.presence || channel.phone_number).to_s
    }
  end

  def initialize(channel:, payload:, verification_context:)
    @channel = channel
    @payload = payload.with_indifferent_access
    @verification_context = verification_context.with_indifferent_access
  end

  def with_verified_route(&)
    return with_unsigned_route(&) unless @verification_context[:hmac_verified] == true
    return false if lock_waba_ids.empty?

    Whatsapp::WabaLock.with_locks(lock_waba_ids) do
      @channel&.reload
      return false unless authenticated_route_matches?

      yield
      true
    end
  end

  private

  def authenticated_route_matches?
    channel_id_matches? && channel_identity_matches? && explicit_route_waba_matches? && waba_ownership_matches?
  end

  def with_unsigned_route
    return false if @channel&.provider == 'whatsapp_cloud'

    yield
    true
  end

  def lock_waba_ids
    @lock_waba_ids ||= (payload_waba_ids + [channel_identity[:waba_id]]).compact_blank.uniq
  end

  def payload_waba_ids
    Array(@payload[:entry]).filter_map { |entry| entry[:id] }.map(&:to_s).uniq
  end

  def channel_identity
    @channel_identity ||= @verification_context[:channel_identity].to_h.with_indifferent_access
  end

  def channel_id_matches?
    expected_channel_id = @verification_context[:channel_id]
    return true if expected_channel_id.blank?
    return true if @channel&.id == expected_channel_id.to_i

    log_identity_change
    false
  end

  def channel_identity_matches?
    return waba_scoped_channel_identity_matches? if @verification_context[:waba_scoped] == true

    if channel_identity.blank?
      return true if @channel.blank?

      log_identity_change
      return false
    end
    return log_identity_change if @channel.blank?

    return true if current_channel_identity == expected_channel_identity

    log_identity_change
    false
  end

  def current_channel_identity
    self.class.identity_snapshot(@channel, @channel.phone_number).with_indifferent_access
  end

  def expected_channel_identity
    channel_identity.merge(account_id: channel_identity[:account_id].to_i)
  end

  def waba_scoped_channel_identity_matches?
    return true if @channel.blank?
    return false unless @channel.provider == 'whatsapp_cloud' && payload_waba_ids.one?

    expected_account_id = @verification_context[:waba_account_ids].to_h.with_indifferent_access[payload_waba_ids.first]
    current_config = @channel.provider_config.to_h
    current_config['business_account_id'].to_s == payload_waba_ids.first && @channel.account_id == expected_account_id.to_i
  end

  def explicit_route_waba_matches?
    return true unless @verification_context[:legacy_signed] == true
    return true if @verification_context[:waba_scoped] == true

    valid = @channel.present? && payload_waba_ids.one? &&
            @channel.provider_config.to_h['business_account_id'].to_s == payload_waba_ids.first
    Rails.logger.warn('[WHATSAPP_WEBHOOK] refused payload because explicit callback WABA does not match payload WABA') unless valid
    valid
  end

  def waba_ownership_matches?
    return @verification_context[:channel_id].present? if payload_waba_ids.empty?

    expected_accounts = @verification_context[:waba_account_ids].to_h.with_indifferent_access
    valid = payload_waba_ids.all? { |waba_id| authenticated_waba_owner?(waba_id, expected_accounts[waba_id]) }
    Rails.logger.warn('[WHATSAPP_WEBHOOK] refused payload because authenticated WABA ownership changed') unless valid
    valid
  end

  def authenticated_waba_owner?(waba_id, expected_account_id)
    return false if expected_account_id.blank?

    Channel::Whatsapp.unambiguous_waba_owner_account_id(waba_id) == expected_account_id.to_i
  end

  def log_identity_change
    Rails.logger.warn('[WHATSAPP_WEBHOOK] refused payload because authenticated channel identity changed')
    false
  end
end
