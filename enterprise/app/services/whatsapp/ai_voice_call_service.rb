class Whatsapp::AiVoiceCallService
  pattr_initialize [:call!, :routing_decision!]

  def perform
    return call unless reserve_call!

    broadcast_ai_answering

    media_session_id = nil
    call_session = nil
    provider_accepted = false

    begin
      session_response = create_media_session
      media_session_id = session_response['session_id']
      meta_sdp_answer = session_response['meta_sdp_answer']

      runtime_contract = create_runtime_agent!(media_session_id)
      call_session = ensure_call_session!(media_session_id, runtime_contract)
      runtime_payload = runtime_payload(media_session_id, runtime_contract, call_session)
      preflight_runtime!(runtime_payload)
      accept_on_provider!(meta_sdp_answer)
      provider_accepted = true
      attach_runtime!(runtime_payload)
      mark_answered!(media_session_id, runtime_contract, call_session)
    rescue StandardError
      terminate_on_provider if provider_accepted
      terminate_media_session(media_session_id) if media_session_id.present?
      mark_failed!(terminal: provider_accepted)
      mark_call_session_failed!(call_session) if call_session.present?
      raise
    end

    broadcast_ai_answered
    call
  end

  private

  def reserve_call!
    @reservation_owner_token = SecureRandom.uuid
    call.with_lock do
      call.reload
      reservation = call.meta.to_h['ai_voice'].to_h
      if reservation['reservation_key'] == runtime_call_ref && reservation['state'].in?(%w[reserving answered failed])
        false
      else
        ensure_ai_routable!
        call.update!(
          meta: call.meta.to_h.merge(
            'ai_voice' => {
              'state' => 'reserving',
              'reservation_key' => runtime_call_ref,
              'reservation_owner_token' => @reservation_owner_token,
              'reserved_at' => Time.current.iso8601
            }
          )
        )
        true
      end
    end
  end

  def ensure_ai_routable!
    raise Whatsapp::CallErrors::NotRinging, 'Call is not in ringing state' unless call.ringing?
    raise Whatsapp::CallErrors::NotRinging, 'Call is not routed to AI voice' unless routing_decision.ai?
    raise Whatsapp::CallErrors::NotRinging, 'Media server is not enabled for AI voice call' unless call.media_server_enabled?
    raise Whatsapp::CallErrors::NotRinging, 'AI voice runtime attach endpoint is not configured' unless runtime_client.enabled?
  end

  def create_media_session
    media_client.create_session(
      call_id: call.provider_call_id,
      direction: 'incoming',
      sdp_offer: call.sdp_offer,
      ice_servers: call.ice_servers,
      account_id: call.account_id
    )
  end

  def accept_on_provider!(meta_sdp_answer)
    pre_response = provider.pre_accept_call(call.provider_call_id, meta_sdp_answer)
    raise Whatsapp::CallErrors::NotRinging, 'Meta pre_accept failed' unless pre_response

    accept_response = provider.accept_call(call.provider_call_id, meta_sdp_answer)
    raise Whatsapp::CallErrors::NotRinging, 'Meta accept failed' unless accept_response
  end

  def create_runtime_agent!(media_session_id)
    media_client.create_runtime_agent(
      media_session_id,
      call_ref: runtime_call_ref,
      account_id: call.account_id,
      conversation_id: call.conversation_id,
      inbox_id: call.inbox_id
    )
  end

  def ensure_call_session!(media_session_id, runtime_contract)
    session = call.account.telephony_call_sessions.find_or_initialize_by(external_call_ref: runtime_call_ref)
    timestamp = Time.current
    session.assign_attributes(
      provider: 'whatsapp_cloud',
      status: 'ringing',
      direction: 'inbound',
      from_number: call.contact&.phone_number,
      to_number: call.inbox&.channel&.try(:phone_number),
      started_at: session.started_at || timestamp,
      conversation: call.conversation,
      contact: call.contact,
      inbox: call.inbox,
      metadata: (session.metadata || {}).deep_merge(
        'ai_voice' => runtime_metadata(media_session_id, runtime_contract),
        'whatsapp_cloud' => { 'provider_call_id' => call.provider_call_id }
      )
    )
    session.save!
    session
  rescue ActiveRecord::RecordNotUnique
    retry
  end

  def runtime_payload(media_session_id, runtime_contract, call_session)
    {
      call_ref: runtime_call_ref,
      account_id: call.account_id,
      inbox_id: call.inbox_id,
      conversation_id: call.conversation_id,
      whatsapp_call_id: call.id,
      provider_call_id: call.provider_call_id,
      media_session_id: media_session_id,
      runtime_stream: runtime_contract,
      call_session_id: call_session.id,
      routing: {
        action: routing_decision.action,
        reason: routing_decision.reason,
        conversation_status: routing_decision.conversation_status,
        captain_assistant_id: routing_decision.assistant&.id
      }.compact
    }
  end

  def preflight_runtime!(payload)
    runtime_client.preflight_call(payload)
  end

  def attach_runtime!(payload)
    runtime_client.attach_call(payload)
  end

  def mark_answered!(media_session_id, runtime_contract, call_session)
    call.with_lock do
      call.reload
      raise Whatsapp::CallErrors::NotRinging, 'AI voice reservation ownership was lost' unless reservation_owned?
      raise Whatsapp::CallErrors::NotRinging, 'Call is not in ringing state' unless call.ringing?

      call.update!(
        status: 'in_progress',
        started_at: Time.current,
        media_session_id: media_session_id,
        meta: (call.meta || {}).merge(
          'ai_voice' => ai_voice_meta('answered', media_session_id, runtime_contract, call_session, preserve_owner: true)
        )
      )
    end

    call_session.update!(
      status: 'in_progress',
      answered_at: call_session.answered_at || Time.current,
      answered_by: 'ai_agent'
    )

    Whatsapp::CallMessageBuilder.update_status!(call: call, status: 'in_progress')
    update_conversation_call_status('ai_answered')
    release_reservation_owner!
  end

  def release_reservation_owner!
    call.with_lock do
      call.reload
      next unless reservation_owned?

      ai_voice = call.meta.to_h['ai_voice'].to_h.except('reservation_owner_token', 'reserved_at')
      call.update!(meta: call.meta.to_h.merge('ai_voice' => ai_voice))
    end
  end

  def mark_failed!(terminal: false)
    call.with_lock do
      call.reload
      next if call.terminal?
      next unless reservation_owned?

      attrs = { meta: (call.meta || {}).merge('ai_voice' => ai_voice_meta('failed')) }
      attrs[:status] = 'failed' if terminal
      call.update!(attrs)
    end
    update_conversation_call_status('ai_failed')
  end

  def mark_call_session_failed!(call_session)
    call_session.update!(
      status: 'failed',
      ended_at: call_session.ended_at || Time.current,
      ended_by: call_session.ended_by || 'system',
      end_reason: call_session.end_reason || 'ai_voice_runtime_attach_failed'
    )
  rescue StandardError => e
    Rails.logger.error "[WHATSAPP AI VOICE CALL] Failed to mark call session #{call_session&.id} failed: #{e.message}"
  end

  def ai_voice_meta(state, media_session_id = nil, runtime_contract = nil, call_session = nil, preserve_owner: false)
    metadata = {
      'state' => state,
      'reservation_key' => runtime_call_ref,
      'captain_assistant_id' => routing_decision.assistant&.id,
      'runtime_transport' => 'whatsapp_cloud',
      'call_ref' => runtime_call_ref,
      'media_session_id' => media_session_id,
      'runtime_session_id' => runtime_contract&.dig('runtime_session_id'),
      'call_session_id' => call_session&.id,
      'updated_at' => Time.current.iso8601
    }.compact
    return metadata unless preserve_owner

    metadata.merge(
      'reservation_owner_token' => @reservation_owner_token,
      'reserved_at' => call.meta.to_h.dig('ai_voice', 'reserved_at')
    ).compact
  end

  def reservation_owned?
    call.meta.to_h.dig('ai_voice', 'reservation_owner_token') == @reservation_owner_token
  end

  def runtime_metadata(media_session_id, runtime_contract)
    {
      'transport' => 'whatsapp_cloud',
      'media_session_id' => media_session_id,
      'runtime_session_id' => runtime_contract&.dig('runtime_session_id'),
      'codec' => runtime_contract&.dig('codec'),
      'input_sample_rate' => runtime_contract&.dig('input_sample_rate'),
      'output_sample_rate' => runtime_contract&.dig('output_sample_rate'),
      'stream_url_present' => runtime_contract&.dig('stream_url').present?
    }.compact
  end

  def runtime_call_ref
    @runtime_call_ref ||= "whatsapp:#{call.provider_call_id}"
  end

  def update_conversation_call_status(call_status)
    conversation = call.conversation
    attrs = (conversation.additional_attributes || {}).merge(
      'call_status' => call_status,
      'call_direction' => call.direction_label
    )
    conversation.update!(additional_attributes: attrs)
  end

  def broadcast_ai_answering
    broadcast('whatsapp_call.ai_answering')
  end

  def broadcast_ai_answered
    broadcast('whatsapp_call.ai_answered', media_session_id: call.media_session_id)
  end

  def broadcast(event, extra_data = {})
    data = {
      account_id: call.account_id,
      id: call.id,
      call_id: call.provider_call_id,
      direction: call.direction_label,
      inbox_id: call.inbox_id,
      conversation_id: call.conversation_id,
      conversation_display_id: call.conversation&.display_id,
      captain_assistant_id: routing_decision.assistant&.id
    }.merge(extra_data).compact

    ActionCable.server.broadcast("account_#{call.account_id}", { event: event, data: data })
  end

  def terminate_on_provider
    provider.terminate_call(call.provider_call_id)
  rescue StandardError => e
    Rails.logger.error "[WHATSAPP AI VOICE CALL] Failed to terminate provider call #{call.provider_call_id}: #{e.message}"
  end

  def terminate_media_session(media_session_id)
    media_client.terminate_session(media_session_id)
  rescue Whatsapp::MediaServerClient::ConnectionError, Whatsapp::MediaServerClient::SessionError => e
    Rails.logger.error "[WHATSAPP AI VOICE CALL] Failed to terminate media session #{media_session_id}: #{e.message}"
  end

  def provider
    @provider ||= call.inbox.channel.provider_service
  end

  def media_client
    @media_client ||= Whatsapp::MediaServerClient.new
  end

  def runtime_client
    @runtime_client ||= Whatsapp::AiVoiceRuntimeClient.new
  end
end
