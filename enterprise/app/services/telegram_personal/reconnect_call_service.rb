class TelegramPersonal::ReconnectCallService
  pattr_initialize [:call!, :agent!]

  def perform
    response = gateway_client.reconnect_call!(call_ref: call_ref)
    offer = TelegramPersonal::JanusMediaConfig.normalize!(response[:agent_offer] || response)
    persist_offer!(offer)
    offer
  rescue TelegramPersonal::CallErrors::NotInProgress
    terminate_closed_call_media
    raise
  end

  private

  def persist_offer!(offer)
    call.with_lock do
      call.reload
      raise TelegramPersonal::CallErrors::NotCallOwner unless call.accepted_by_agent_id == agent.id
      raise TelegramPersonal::CallErrors::NotInProgress unless call.in_progress?

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
