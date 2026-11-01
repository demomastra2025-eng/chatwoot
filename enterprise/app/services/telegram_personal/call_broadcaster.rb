class TelegramPersonal::CallBroadcaster
  class << self
    def broadcast_incoming(call)
      conversation = call.conversation
      contact = call.contact || conversation&.contact
      thread_id = communication_thread_display_id(conversation)
      data = incoming_payload(call, conversation, contact, thread_id)
      offer = call.meta&.dig('agent_offer')
      data[:agent_offer] = offer if offer.is_a?(Hash) && offer['sdp_offer'].present?

      broadcast(call.account_id, 'telegram_personal_call.incoming', data)
    end

    def broadcast_accepted(call, agent)
      broadcast(
        call.account_id,
        'telegram_personal_call.accepted',
        {
          account_id: call.account_id,
          id: call.id,
          call_id: call.provider_call_id,
          provider: 'telegram_personal',
          accepted_by_agent_id: agent.id,
          conversation_id: call.conversation_id
        }
      )
    end

    def broadcast_agent_offer(call, agent, offer)
      return if offer.blank?

      broadcast(
        call.account_id,
        'telegram_personal_call.agent_offer',
        {
          account_id: call.account_id,
          id: call.id,
          call_id: call.provider_call_id,
          provider: 'telegram_personal',
          conversation_id: call.conversation_id,
          conversation_display_id: call.conversation&.display_id,
          accepted_by_agent_id: agent.id,
          sdp_offer: offer['sdp_offer'],
          peer_id: offer['peer_id'],
          ice_servers: offer['ice_servers']
        }
      )
    end

    def broadcast_outbound_accepted(call)
      broadcast(
        call.account_id,
        'telegram_personal_call.outbound_accepted',
        {
          account_id: call.account_id,
          id: call.id,
          call_id: call.provider_call_id,
          provider: 'telegram_personal',
          conversation_id: call.conversation_id,
          status: 'in-progress'
        }
      )
    end

    def broadcast_ended(call)
      broadcast(
        call.account_id,
        'telegram_personal_call.ended',
        {
          account_id: call.account_id,
          id: call.id,
          call_id: call.provider_call_id,
          provider: 'telegram_personal',
          status: call.status,
          duration_seconds: call.duration_seconds,
          conversation_id: call.conversation_id
        }
      )
    end

    def caller_info(call)
      conversation = call.conversation
      contact = call.contact || conversation&.contact
      return {} unless contact

      {
        name: contact.name,
        phone: contact.phone_number.presence || telegram_handle(conversation, contact),
        avatar: contact.avatar_url
      }
    end

    def communication_thread_display_id(conversation)
      return if conversation.blank?

      (conversation.communication_thread || conversation.refresh_communication_thread!)&.display_id
    end

    def normalize_agent_offer(offer)
      return if offer.blank?

      normalized = offer.to_h.stringify_keys.slice('peer_id', 'sdp_offer', 'ice_servers')
      normalized['sdp_offer'].present? ? normalized : nil
    end

    def merged_agent_offer_meta(raw_meta, agent_id, offer)
      meta = raw_meta || {}
      return meta if offer.blank?

      agent_offers = (meta['agent_offers'] || {}).merge(agent_id.to_s => offer)
      meta.merge(
        'agent_offer' => offer,
        'agent_offers' => agent_offers,
        'agent_offer_generated_at' => meta['agent_offer_generated_at'] || Time.zone.now.to_i
      )
    end

    def unique_provider_call_id(inbox_id, raw_id, current_call_id: nil)
      raw = raw_id.to_s
      scope = Call.telegram_personal.where(provider_call_id: raw).where.not(inbox_id: inbox_id)
      scope = scope.where.not(id: current_call_id) if current_call_id
      scope.exists? ? "#{inbox_id}:#{raw}" : raw
    end

    private

    def incoming_payload(call, conversation, contact, thread_id)
      {
        account_id: call.account_id,
        id: call.id,
        call_id: call.provider_call_id,
        provider: 'telegram_personal',
        direction: call.direction_label,
        inbox_id: call.inbox_id,
        conversation_id: call.conversation_id,
        conversation_display_id: conversation&.display_id,
        communication_thread_id: thread_id,
        communicationThreadId: thread_id,
        media_session_id: call.media_session_id,
        media_server_enabled: true,
        caller: contact ? caller_info(call) : {}
      }
    end

    def telegram_handle(conversation, contact)
      username = conversation&.additional_attributes&.dig('username').presence ||
                 contact.additional_attributes&.dig('social_telegram_user_name').presence
      "@#{username.to_s.delete_prefix('@')}" if username.present?
    end

    def broadcast(account_id, event, data)
      ActionCable.server.broadcast("account_#{account_id}", { event: event, data: data })
    end
  end
end
