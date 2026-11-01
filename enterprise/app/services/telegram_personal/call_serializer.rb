class TelegramPersonal::CallSerializer
  class << self
    def show(call, current_user)
      thread_id = TelegramPersonal::CallBroadcaster.communication_thread_display_id(call.conversation)
      {
        id: call.id, call_id: call.provider_call_id, provider: 'telegram_personal',
        status: call.status, direction: call.direction_label, conversation_id: call.conversation_id,
        conversation_display_id: call.conversation&.display_id, communication_thread_id: thread_id,
        communicationThreadId: thread_id, inbox_id: call.inbox_id, message_id: call.message_id,
        media_session_id: call.media_session_id, sdp_offer: nil, ice_servers: [],
        media_server_enabled: true, caller: TelegramPersonal::CallBroadcaster.caller_info(call),
        agent_offer: call.ringing? ? agent_offer_for_user(call, current_user) : nil
      }
    end

    def active(call)
      thread_id = TelegramPersonal::CallBroadcaster.communication_thread_display_id(call.conversation)
      elapsed = call.started_at ? (Time.current - call.started_at).to_i : 0
      {
        id: call.id, call_id: call.provider_call_id, provider: 'telegram_personal',
        direction: call.direction_label, conversation_id: call.conversation_id,
        conversation_display_id: call.conversation&.display_id, communication_thread_id: thread_id,
        communicationThreadId: thread_id, inbox_id: call.inbox_id, status: call.status,
        elapsed_seconds: elapsed, media_session_id: call.media_session_id,
        media_server_enabled: true, caller: TelegramPersonal::CallBroadcaster.caller_info(call)
      }
    end

    def dial(call, provider_call_id)
      {
        id: call.id, status: call.status, call_id: provider_call_id,
        provider: 'telegram_personal', message_id: call.message_id, media_session_id: call.media_session_id
      }
    end

    def outbound_initiate(call)
      payload = {
        status: 'calling', call_id: call.provider_call_id, provider: 'telegram_personal',
        id: call.id, message_id: call.message_id, media_session_id: call.media_session_id,
        media_server_enabled: true
      }.compact
      offer = normalize_offer(call.meta&.dig('agent_offer'))
      payload[:agent_offer] = offer if offer.present?
      payload
    end

    def media_server_accept(call, agent_offer)
      thread_id = TelegramPersonal::CallBroadcaster.communication_thread_display_id(call.conversation)
      {
        id: call.id, status: call.status, provider: 'telegram_personal',
        message_id: call.message_id, media_session_id: call.media_session_id,
        conversation_id: call.conversation_id, conversation_display_id: call.conversation&.display_id,
        communication_thread_id: thread_id, communicationThreadId: thread_id,
        agent_offer: normalize_offer(agent_offer)
      }.compact
    end

    def normalize_offer(offer)
      return if offer.blank?

      offer.to_h.stringify_keys.slice('peer_id', 'sdp_offer', 'ice_servers')
    end

    private

    def agent_offer_for_user(call, current_user)
      meta = call.meta || {}
      normalize_offer(meta.dig('agent_offers', current_user.id.to_s) || meta['agent_offer'])
    end
  end
end
