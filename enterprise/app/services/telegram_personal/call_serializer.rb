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
        agent_offer: agent_offer_for_user(call, current_user)
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

    def outbound_initiate(call, current_user)
      payload = {
        status: 'calling', call_id: call.provider_call_id, provider: 'telegram_personal',
        id: call.id, message_id: call.message_id, media_session_id: call.media_session_id,
        media_server_enabled: true
      }.compact
      offer = agent_offer_for_user(call, current_user)
      payload[:agent_offer] = offer if offer.present?
      payload
    end

    def media_server_accept(call, agent_offer, current_user)
      thread_id = TelegramPersonal::CallBroadcaster.communication_thread_display_id(call.conversation)
      {
        id: call.id, status: call.status, call_id: call.provider_call_id, inbox_id: call.inbox_id, provider: 'telegram_personal',
        message_id: call.message_id, media_session_id: call.media_session_id,
        conversation_id: call.conversation_id, conversation_display_id: call.conversation&.display_id,
        communication_thread_id: thread_id, communicationThreadId: thread_id,
        agent_offer: agent_offer_for_user(call, current_user, offer: agent_offer)
      }.compact
    end

    def agent_offer_for_user(call, current_user, offer: nil)
      return unless accessible_call?(call, current_user)

      meta = call.meta.to_h
      normalize_offer(offer || meta.dig('agent_offers', current_user.id.to_s) || meta['agent_offer'])
    end

    def accessible_call?(call, user)
      return false unless owned_active_call?(call, user)

      membership = AccountUser.find_by(account_id: call.account_id, user_id: user.id)
      return false unless membership && call.conversation

      ConversationPolicy.new({ user: user, account: call.account, account_user: membership }, call.conversation).show?
    end

    def owned_active_call?(call, user)
      return false if call.blank? || user.blank? || !call.telegram_personal?

      call.accepted_by_agent_id == user.id && call.media_session_id.present? && active_media_state?(call)
    end

    def active_media_state?(call)
      call.in_progress? || (call.outgoing? && call.ringing? && call.meta.to_h['outbound_prepare_pending'] == true)
    end

    def normalize_offer(offer)
      TelegramPersonal::CallBroadcaster.normalize_agent_offer(offer)
    end
  end
end
