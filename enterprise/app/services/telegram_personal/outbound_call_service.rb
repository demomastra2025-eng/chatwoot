class TelegramPersonal::OutboundCallService
  pattr_initialize [:account!, :user!]

  def prepare!(conversation)
    recipient_id, username = resolve_outbound_target!(conversation)
    client = gateway_client(conversation)
    session_id = nil

    response = client.prepare_outbound_call!(
      recipient_id: recipient_id,
      phone_number: conversation.contact&.phone_number,
      username: username
    )
    session_id = response[:session_id].to_s.presence
    raise ArgumentError, 'Gateway session_id not returned' if session_id.blank?

    call = build_prepared_call!(conversation, response, session_id)
    attach_outbound_message!(conversation, call)
    schedule_call_cleanup(call)
    call
  rescue StandardError
    terminate_orphan_gateway_session(client, session_id) if client
    raise
  end

  def prepared_for_user?(call)
    call.outgoing? &&
      call.media_session_id.present? &&
      call.meta&.dig('outbound_prepare_pending') == true &&
      call.meta&.dig('outbound_dialing') != true &&
      call.accepted_by_agent_id == user.id
  end

  def dial!(call)
    claim_prepared_outbound_dial!(call)
    response = gateway_client(call.conversation).dial_call!(call_ref: gateway_call_ref(call))
    provider_call_id = response[:call_id].to_s.presence
    raise ArgumentError, 'Telegram call_id not returned' if provider_call_id.blank?

    update_prepared_outbound_provider_ref!(call, provider_call_id)
    schedule_call_cleanup(call)
    provider_call_id
  rescue StandardError
    mark_prepared_outbound_failed(call) if call&.persisted?
    raise
  end

  private

  def build_prepared_call!(conversation, response, session_id)
    agent_offer = TelegramPersonal::CallBroadcaster.normalize_agent_offer(response[:agent_offer])
    pending_call_id = response[:call_id].to_s.presence || "pending_#{session_id}"

    account.calls.create!(
      provider: :telegram_personal,
      inbox: conversation.inbox,
      conversation: conversation,
      contact: conversation.contact,
      provider_call_id: pending_call_id,
      direction: :outgoing,
      status: 'ringing',
      accepted_by_agent_id: user.id,
      media_session_id: session_id,
      meta: prepared_call_meta(agent_offer)
    )
  end

  def prepared_call_meta(agent_offer)
    now = Time.zone.now.to_i
    {
      'outbound_prepare_pending' => true,
      'outbound_prepared_at' => now,
      'agent_offer_generated_at' => now,
      'agent_offer' => agent_offer
    }.compact
  end

  def attach_outbound_message!(conversation, call)
    message = TelegramPersonal::CallMessageBuilder.create!(conversation: conversation, call: call, user: user)
    call.update!(message_id: message.id)
  end

  def resolve_outbound_target!(conversation)
    recipient_id = source_or_peer_id(conversation)
    username = telegram_username(conversation)
    phone = conversation.contact&.phone_number.presence
    target = recipient_id || username || phone
    raise ArgumentError, 'Telegram recipient identifier not available' if target.blank?

    [target, username]
  end

  def source_or_peer_id(conversation)
    conversation.contact_inbox&.source_id.to_s.presence ||
      conversation.additional_attributes&.dig('peer_user_id').to_s.presence
  end

  def telegram_username(conversation)
    conversation.additional_attributes&.dig('username').to_s.presence ||
      conversation.contact&.additional_attributes&.dig('social_telegram_user_name').to_s.presence
  end

  def claim_prepared_outbound_dial!(call)
    call.with_lock do
      call.reload
      raise ArgumentError, 'Call is not an outbound prepared call' unless prepared_for_user?(call)

      call.update!(meta: (call.meta || {}).merge('outbound_dialing' => true))
    end
  end

  def update_prepared_outbound_provider_ref!(call, provider_call_id)
    stored_id = TelegramPersonal::CallBroadcaster.unique_provider_call_id(
      call.inbox_id, provider_call_id, current_call_id: call.id
    )
    call.with_lock do
      call.reload
      meta = (call.meta || {}).merge(
        'outbound_prepare_pending' => false,
        'outbound_dialing' => false,
        'outbound_dialed_at' => Time.zone.now.to_i
      )
      attrs = { meta: meta }
      attrs[:provider_call_id] = stored_id if call.provider_call_id.to_s.start_with?('pending_')
      call.update!(attrs)
    end
    update_outbound_call_message_provider_ref!(call, call.provider_call_id)
  end

  def update_outbound_call_message_provider_ref!(call, provider_call_id)
    message = call.message
    return unless message

    attrs = (message.content_attributes || {}).dup
    attrs['data'] ||= {}
    attrs['data']['call_sid'] = provider_call_id
    message.update!(source_id: "tg_call_#{provider_call_id}", content_attributes: attrs)
  end

  def mark_prepared_outbound_failed(call)
    call.with_lock do
      call.reload
      failed_meta = (call.meta || {}).merge('outbound_prepare_pending' => false, 'outbound_dialing' => false)
      call.update!(status: 'failed', meta: failed_meta) unless call.terminal?
    end
    TelegramPersonal::CallMessageBuilder.update_status!(call: call.reload, status: 'failed')
    terminate_orphan_gateway_session(gateway_client(call.conversation), call.media_session_id)
  rescue StandardError => e
    Rails.logger.error "[TELEGRAM CALL] Failed to mark prepared outbound failed #{call&.id}: #{e.message}"
  end

  def terminate_orphan_gateway_session(client, session_id)
    return if session_id.blank?

    client.terminate_call!(call_ref: session_id)
  rescue StandardError => e
    Rails.logger.warn "[TELEGRAM CALL] Failed to terminate orphan session #{session_id}: #{e.message}"
  end

  def gateway_client(conversation)
    TelegramPersonal::GatewayClient.new(channel: conversation.inbox.channel)
  end

  def gateway_call_ref(call)
    call.media_session_id.presence || call.provider_call_id
  end

  def schedule_call_cleanup(call)
    TelegramPersonal::CallCleanupJob.set(wait: TelegramPersonal::IncomingCallService::RINGING_CLEANUP_DELAY).perform_later(call.id)
  end
end
