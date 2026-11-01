class TelegramPersonal::ReconnectCallService
  # A runtime-sync retry can make three bounded 60-second HTTP requests.
  RECONNECT_LOCK_TTL = 5.minutes.to_i

  pattr_initialize [:call!, :agent!]

  def perform
    with_reconnect_lock do |lock|
      call.reload
      validate_call!
      response = gateway_client.reconnect_call!(call_ref: call_ref)
      offer = TelegramPersonal::JanusMediaConfig.normalize!(response[:agent_offer] || response)
      raise_reconnect_conflict! unless lock.renew(reconnect_lock_key, RECONNECT_LOCK_TTL)

      persist_offer!(offer)
      offer
    end
  rescue TelegramPersonal::CallErrors::NotInProgress
    terminate_closed_call_media
    raise
  end

  private

  def with_reconnect_lock
    lock = Redis::LockManager.new
    acquired = lock.lock(reconnect_lock_key, RECONNECT_LOCK_TTL)
    raise_reconnect_conflict! unless acquired

    yield lock
  ensure
    lock&.unlock(reconnect_lock_key) if acquired
  end

  def reconnect_lock_key
    "telegram_personal:media_reconnect:#{call.account_id}:#{call.id}"
  end

  def raise_reconnect_conflict!
    raise Telephony::Error.new(
      code: 'CALL_RECONNECT_IN_PROGRESS', message: 'Another call reconnect is already in progress', status: :conflict
    )
  end

  def validate_call!
    raise TelegramPersonal::CallErrors::NotCallOwner unless call.accepted_by_agent_id == agent.id
    raise TelegramPersonal::CallErrors::NotInProgress unless call.in_progress?
  end

  def persist_offer!(offer)
    call.with_lock do
      call.reload
      validate_call!
      call.update!(meta: TelegramPersonal::CallBroadcaster.merged_agent_offer_meta(call.meta, agent.id, offer))
    end
  end

  def call_ref
    call.media_session_id.presence || call.provider_call_id
  end

  def gateway_client
    @gateway_client ||= TelegramPersonal::GatewayClient.new(channel: call.inbox.channel)
  end

  def terminate_closed_call_media
    gateway_client.terminate_call!(call_ref: call_ref) if call.terminal?
  rescue TelegramPersonal::GatewayClient::GatewayError => e
    Rails.logger.warn(event: 'telegram_janus_reconnect_cleanup_failed', call_id: call.id, error: e.class.name)
  end
end
