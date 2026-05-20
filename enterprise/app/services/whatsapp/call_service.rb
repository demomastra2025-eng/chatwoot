class Whatsapp::CallService
  pattr_initialize [:call!, :agent!]

  attr_reader :agent_offer

  def accept(params = {})
    if media_server_enabled?
      accept_via_media_server
    else
      pre_accept_and_accept(params[:sdp_answer])
    end
  end

  def pre_accept_and_accept(sdp_answer)
    call.with_lock do
      ensure_ringing!
      ensure_not_already_taken!

      provider = call.inbox.channel.provider_service
      fixed_sdp = fix_sdp_setup(sdp_answer)

      # Step 1: pre_accept (with SDP answer - required by Meta)
      pre_response = provider.pre_accept_call(call.provider_call_id, fixed_sdp)
      raise Whatsapp::CallErrors::NotRinging, 'Meta pre_accept failed' unless pre_response

      # Step 2: accept with same SDP answer
      accept_response = provider.accept_call(call.provider_call_id, fixed_sdp)
      raise Whatsapp::CallErrors::NotRinging, 'Meta accept failed' unless accept_response

      call.update!(
        status: 'in_progress',
        accepted_by_agent_id: agent.id,
        started_at: Time.current
      )
    end

    Whatsapp::CallMessageBuilder.update_status!(call: call, status: 'in_progress', agent: agent)
    update_conversation_call_status('in-progress')
    broadcast_accepted
    call
  end

  def reject
    provider_call_id = nil
    transitioned = false

    call.with_lock do
      call.reload
      unless call.terminal? || call.in_progress?
        provider_call_id = call.provider_call_id
        call.update!(status: 'failed')
        transitioned = true
      end
    end

    if transitioned
      reject_on_provider(provider_call_id)
      after_status_transition(status: 'failed')
    end

    call
  end

  def terminate
    provider_call_id = nil
    media_session_id = nil
    transitioned = false
    target_status = 'completed'

    call.with_lock do
      call.reload
      unless call.terminal?
        prepared_outbound = prepared_outbound_pending?
        provider_call_id = prepared_outbound ? nil : call.provider_call_id
        media_session_id = call.media_session_id
        target_status = prepared_outbound ? 'failed' : 'completed'
        end_reason = prepared_outbound ? 'agent_setup_failed' : call.end_reason.presence || 'agent_terminated'
        meta = prepared_outbound ? (call.meta || {}).merge('outbound_prepare_pending' => false, 'outbound_dialing' => false) : call.meta
        call.update!(status: target_status, end_reason: end_reason, meta: meta)
        transitioned = true
      end
    end

    if transitioned
      terminate_on_provider(provider_call_id)
      terminate_media_session(media_session_id) if media_session_id.present?
      after_status_transition(status: target_status)
    end

    call
  end

  def terminate_on_provider(provider_call_id = call.provider_call_id)
    return if provider_call_id.blank?

    provider = call.inbox.channel.provider_service
    success = provider.terminate_call(provider_call_id)
    Rails.logger.error "[WHATSAPP CALL] terminate_call API returned false for call #{provider_call_id}" unless success
  rescue StandardError => e
    Rails.logger.error "[WHATSAPP CALL] Failed to terminate call #{provider_call_id} on provider: #{e.message}"
  end

  private

  def accept_via_media_server
    client = Whatsapp::MediaServerClient.new
    provider = call.inbox.channel.provider_service
    media_session_id = nil
    agent_offer = nil
    provider_accepted = false

    reserve_acceptance!

    begin
      prepared = prepared_media_session(client)
      if prepared
        media_session_id = prepared[:media_session_id]
        agent_offer = prepared[:agent_offer]
        @agent_offer = agent_offer
        meta_sdp_answer = prepared[:meta_sdp_answer]
      else
        # Step 1: Create session on Go server with Meta's SDP
        session_response = client.create_session(
          call_id: call.provider_call_id,
          direction: 'incoming',
          sdp_offer: call.sdp_offer,
          ice_servers: call.ice_servers,
          account_id: call.account_id
        )
        media_session_id = session_response['session_id']
        meta_sdp_answer = session_response['meta_sdp_answer']

        # Step 2: Generate agent offer (Peer B) before provider accept. This
        # shaves a full media-server round-trip from the caller's short accept
        # window; the browser can answer as soon as /accept returns.
        agent_offer = client.generate_agent_offer(media_session_id)
        @agent_offer = agent_offer
      end

      # Step 3: Send Go-generated SDP answer to Meta
      pre_response = provider.pre_accept_call(call.provider_call_id, meta_sdp_answer)
      raise Whatsapp::CallErrors::NotRinging, 'Meta pre_accept failed' unless pre_response

      accept_response = provider.accept_call(call.provider_call_id, meta_sdp_answer)
      raise Whatsapp::CallErrors::NotRinging, 'Meta accept failed' unless accept_response

      provider_accepted = true

      # Step 4: Update call record
      call.with_lock do
        call.reload
        ensure_ringing!
        raise Whatsapp::CallErrors::AlreadyAccepted, 'Call already accepted by another agent' if call.accepted_by_agent_id != agent.id

        call.update!(
          status: 'in_progress',
          started_at: Time.current,
          media_session_id: media_session_id,
          meta: merged_media_meta(meta_sdp_answer, agent_offer)
        )
      end
    rescue StandardError
      terminate_on_provider(call.provider_call_id) if provider_accepted
      terminate_media_session(media_session_id) if media_session_id.present?
      clear_failed_media_preparation!(media_session_id)
      release_acceptance_reservation!
      raise
    end

    cleanup_losing_prepared_peers(media_session_id, agent_offer)

    # Step 5: Broadcast events (outside lock)
    Whatsapp::CallMessageBuilder.update_status!(call: call, status: 'in_progress', agent: agent)
    update_conversation_call_status('in-progress')
    broadcast_agent_offer(agent_offer)
    broadcast_accepted
    call
  end

  def media_server_enabled?
    call.media_server_enabled?
  end

  def prepared_outbound_pending?
    call.outgoing? && call.meta&.dig('outbound_prepare_pending') == true
  end

  def prepared_media_session(client)
    call.reload
    meta = call.meta || {}
    return if call.media_session_id.blank? || meta['media_sdp_answer'].blank?

    offer = prepared_agent_offer_for(meta)
    offer ||= create_agent_offer_for_agent(client, call.media_session_id)
    promote_agent_peer(client, call.media_session_id, offer)

    {
      media_session_id: call.media_session_id,
      meta_sdp_answer: meta['media_sdp_answer'],
      agent_offer: offer
    }
  end

  def prepared_agent_offer_for(meta)
    offer = meta.dig('agent_offers', agent.id.to_s)
    offer = meta['agent_offer'] if offer.blank? && meta.dig('agent_offer', 'sdp_offer').present?
    normalize_agent_offer(offer)
  end

  def create_agent_offer_for_agent(client, media_session_id)
    response = client.add_peer(media_session_id, role: 'active', label: agent.name.presence || "Agent ##{agent.id}")
    normalize_agent_offer(response)
  end

  def promote_agent_peer(client, media_session_id, offer)
    return if offer['peer_id'].blank?

    client.change_peer_role(media_session_id, peer_id: offer['peer_id'], role: 'active')
  end

  def normalize_agent_offer(offer)
    return if offer.blank?

    normalized = offer.to_h.stringify_keys.slice('peer_id', 'sdp_offer', 'ice_servers')
    normalized['sdp_offer'].present? ? normalized : nil
  end

  def merged_media_meta(meta_sdp_answer, agent_offer)
    meta = call.meta || {}
    agent_offers = (meta['agent_offers'] || {}).merge(agent.id.to_s => agent_offer)
    meta.merge(
      'media_sdp_answer' => meta_sdp_answer,
      'agent_offer' => agent_offer,
      'agent_offers' => agent_offers,
      'agent_offer_generated_at' => meta['agent_offer_generated_at'] || Time.zone.now.to_i
    )
  end

  def reserve_acceptance!
    call.with_lock do
      call.reload
      ensure_ringing!
      ensure_not_already_taken!
      call.update!(accepted_by_agent_id: agent.id)
    end
  end

  def release_acceptance_reservation!
    call.with_lock do
      call.reload
      call.update!(accepted_by_agent_id: nil) if call.ringing? && call.accepted_by_agent_id == agent.id
    end
  end

  def clear_failed_media_preparation!(media_session_id)
    return if media_session_id.blank?

    call.with_lock do
      call.reload
      next unless call.ringing? && call.media_session_id == media_session_id

      meta = (call.meta || {}).except('media_sdp_answer', 'agent_offer', 'agent_offers', 'agent_offer_generated_at')
      call.update!(media_session_id: nil, meta: meta)
    end
  end

  def cleanup_losing_prepared_peers(media_session_id, winning_offer)
    winning_peer_id = winning_offer&.dig('peer_id')
    return if media_session_id.blank? || winning_peer_id.blank?

    meta = call.reload.meta || {}
    offers = meta['agent_offers'] || {}
    loser_offers = offers.except(agent.id.to_s)
    client = Whatsapp::MediaServerClient.new
    loser_offers.each_value do |offer|
      peer_id = offer['peer_id'] || offer[:peer_id]
      client.remove_peer(media_session_id, peer_id: peer_id) if peer_id.present?
    rescue Whatsapp::MediaServerClient::ConnectionError, Whatsapp::MediaServerClient::SessionError => e
      Rails.logger.warn "[WHATSAPP CALL] failed to remove losing prepared peer #{peer_id}: #{e.message}"
    end

    call.update!(meta: meta.merge('agent_offers' => { agent.id.to_s => winning_offer })) if loser_offers.present?
  end

  def terminate_media_session(media_session_id)
    return if media_session_id.blank?

    Whatsapp::MediaServerClient.new.terminate_session(media_session_id)
  rescue Whatsapp::MediaServerClient::ConnectionError, Whatsapp::MediaServerClient::SessionError => e
    Rails.logger.error "[WHATSAPP CALL] Failed to terminate media session #{media_session_id}: #{e.message}"
  end

  def reject_on_provider(provider_call_id)
    provider = call.inbox.channel.provider_service
    success = provider.reject_call(provider_call_id)
    Rails.logger.error "[WHATSAPP CALL] reject_call API returned false for call #{provider_call_id}" unless success
  rescue StandardError => e
    Rails.logger.error "[WHATSAPP CALL] Failed to reject call #{provider_call_id} on provider: #{e.message}"
  end

  def after_status_transition(status:, agent: nil, duration_seconds: nil)
    Whatsapp::CallMessageBuilder.update_status!(call: call, status: status, agent: agent, duration_seconds: duration_seconds)
    mapped_status = Whatsapp::CallMessageBuilder::CALL_TO_VOICE_STATUS[status] || status
    update_conversation_call_status(mapped_status)
    broadcast_call_ended
  end

  def ensure_ringing!
    raise Whatsapp::CallErrors::NotRinging, 'Call is not in ringing state' unless call.ringing?
  end

  def ensure_not_already_taken!
    already_reserved_by_other_agent = call.accepted_by_agent_id.present? && call.accepted_by_agent_id != agent.id
    return unless call.in_progress? || already_reserved_by_other_agent

    raise Whatsapp::CallErrors::AlreadyAccepted, 'Call already accepted by another agent'
  end

  def fix_sdp_setup(sdp)
    sdp.gsub('a=setup:actpass', 'a=setup:active')
  end

  def update_conversation_call_status(mapped_status)
    conversation = call.conversation
    attrs = (conversation.additional_attributes || {}).merge('call_status' => mapped_status)
    conversation.update!(additional_attributes: attrs)
  end

  def broadcast_accepted
    payload = {
      event: 'whatsapp_call.accepted',
      data: {
        account_id: call.account_id,
        id: call.id,
        call_id: call.provider_call_id,
        accepted_by_agent_id: agent.id,
        conversation_id: call.conversation_id
      }
    }
    ActionCable.server.broadcast("account_#{call.account_id}", payload)
  end

  def broadcast_agent_offer(agent_offer)
    payload = {
      event: 'whatsapp_call.agent_offer',
      data: {
        account_id: call.account_id,
        id: call.id,
        call_id: call.provider_call_id,
        conversation_id: call.conversation_id,
        conversation_display_id: call.conversation&.display_id,
        accepted_by_agent_id: agent.id,
        sdp_offer: agent_offer['sdp_offer'],
        peer_id: agent_offer['peer_id'],
        ice_servers: agent_offer['ice_servers']
      }
    }
    ActionCable.server.broadcast("account_#{call.account_id}", payload)
  end

  def broadcast_call_ended
    payload = {
      event: 'whatsapp_call.ended',
      data: {
        account_id: call.account_id,
        id: call.id,
        call_id: call.provider_call_id,
        status: call.status,
        conversation_id: call.conversation_id
      }
    }
    ActionCable.server.broadcast("account_#{call.account_id}", payload)
  end
end
