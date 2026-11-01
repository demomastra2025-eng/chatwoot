class TelegramPersonal::IncomingCallService
  FAILURE_REASONS = %w[failed error rejected busy declined handshake_failed setup_timeout cancelled canceled].freeze
  RINGING_CLEANUP_DELAY = 95.seconds

  pattr_initialize [:inbox!, :event!, :params!]

  def perform
    case event.to_s
    when 'call.incoming' then handle_call_incoming
    when 'call.accepted' then handle_call_accepted
    when 'call.ended' then handle_call_ended
    else Rails.logger.warn "[TELEGRAM CALL] Unknown call event: #{event}"
    end
  end

  private

  def calling_enabled?
    channel = inbox.channel
    channel.respond_to?(:voice_enabled?) ? channel.voice_enabled? : true
  end

  def handle_call_incoming
    return unless calling_enabled?

    provider_call_id = params[:call_id].to_s.presence
    return if provider_call_id.blank? || find_existing_call(provider_call_id, params[:session_id]).present?

    contact_inbox, conversation = sync_contact_and_conversation
    return if conversation.blank?

    finalize_incoming_call(conversation, contact_inbox.contact, provider_call_id)
  rescue ActiveRecord::RecordNotUnique
    Rails.logger.warn "[TELEGRAM CALL] Duplicate incoming call #{params[:call_id]}; ignoring"
  end

  def finalize_incoming_call(conversation, contact, provider_call_id)
    call = create_incoming_call(conversation, contact, provider_call_id)
    schedule_call_cleanup(call)
    create_voice_call_message(conversation, call)
    update_conversation_call_status(conversation, 'ringing', call.direction_label)
    TelegramPersonal::CallBroadcaster.broadcast_incoming(call)
    TelegramCalls::CallDispatcher.dispatch_telegram_personal_call(call)
  end

  def handle_call_accepted
    call = find_existing_call(params[:call_id], params[:session_id])
    return Rails.logger.warn("[TELEGRAM CALL] Accepted event for unknown call #{params[:call_id]}") if call.nil?
    return unless transition_outbound_to_in_progress!(call)

    TelegramPersonal::CallMessageBuilder.update_status!(call: call, status: 'in_progress', agent: call.accepted_by_agent)
    update_conversation_call_status(call.conversation, 'in-progress', call.direction_label)
    TelegramPersonal::CallBroadcaster.broadcast_outbound_accepted(call)
  end

  def transition_outbound_to_in_progress!(call)
    transitioned = false
    call.with_lock do
      call.reload
      sync_real_provider_call_id!(call)
      if call.outgoing? && !call.in_progress? && !call.terminal?
        call.update!(status: 'in_progress', started_at: Time.current)
        transitioned = true
      end
    end
    transitioned
  end

  def handle_call_ended
    call = find_existing_call(params[:call_id], params[:session_id])
    return Rails.logger.warn("[TELEGRAM CALL] Ended event for unknown call #{params[:call_id]}") if call.nil?

    duration = params[:duration_seconds]&.to_i
    end_reason = params[:end_reason].to_s.presence
    final_status = transition_to_ended!(call, duration, end_reason)
    return if final_status.blank?

    finalize_ended_call!(call, final_status, duration)
  end

  def transition_to_ended!(call, duration, end_reason)
    final_status = nil
    call.with_lock do
      call.reload
      sync_real_provider_call_id!(call)
      next if call.terminal?

      final_status = derive_terminal_status(call, duration, end_reason)
      ended_meta = (call.meta || {}).merge('ended_at' => Time.zone.now.to_i)
      call.update!(status: final_status, duration_seconds: duration, end_reason: end_reason, meta: ended_meta)
    end
    final_status
  end

  def finalize_ended_call!(call, final_status, duration)
    agent = call.accepted_by_agent if call.accepted_by_agent_id.present?
    TelegramPersonal::CallMessageBuilder.update_status!(
      call: call, status: final_status, agent: agent, duration_seconds: duration
    )
    mapped = TelegramPersonal::CallMessageBuilder::CALL_TO_VOICE_STATUS[final_status] || final_status
    update_conversation_call_status(call.conversation, mapped, call.direction_label)
    TelegramPersonal::CallBroadcaster.broadcast_ended(call)
    TelegramCalls::CallDispatcher.cancel_legs_for_source!(
      source_type: 'telegram_personal', account_id: call.account_id, source_call_ref: call.id.to_s,
      status_text: '✅ <b>Звонок завершён</b>', include_claimed: true
    )
    enqueue_recording_fetch(call)
  end

  def enqueue_recording_fetch(call)
    return if call.media_session_id.blank?
    return if params.key?(:has_recording) && ActiveModel::Type::Boolean.new.cast(params[:has_recording]) == false

    TelegramPersonal::CallRecordingFetchJob.perform_later(call.id)
  end

  def find_existing_call(provider_call_id, session_id)
    scope = Call.telegram_personal.where(account_id: inbox.account_id, inbox_id: inbox.id)
    if provider_call_id.present?
      raw = provider_call_id.to_s
      call = scope.find_by(provider_call_id: [raw, "#{inbox.id}:#{raw}"])
    end
    call ||= scope.find_by(media_session_id: session_id.to_s) if session_id.present?
    call
  end

  def sync_real_provider_call_id!(call)
    real_id = params[:call_id].to_s.presence
    return if real_id.blank? || real_id.start_with?('pending_')
    return unless call.provider_call_id.to_s.start_with?('pending_')

    stored_id = TelegramPersonal::CallBroadcaster.unique_provider_call_id(inbox.id, real_id, current_call_id: call.id)
    call.update!(provider_call_id: stored_id)
    TelegramPersonal::CallMessageBuilder.update_call_sid!(call: call, call_sid: stored_id)
  end

  def derive_terminal_status(call, duration, reason)
    explicit = params[:status].to_s
    return explicit if Call::TERMINAL_STATUSES.include?(explicit)

    normalized_reason = reason.to_s.downcase
    return 'completed' if normalized_reason == 'answered_elsewhere'
    return 'failed' if FAILURE_REASONS.any? { |item| normalized_reason.include?(item) }

    answered?(call, duration) ? 'completed' : 'no_answer'
  end

  def answered?(call, duration)
    call.in_progress? || duration.to_i.positive? || (call.incoming? && call.accepted_by_agent_id.present?)
  end

  def sync_contact_and_conversation
    contact_inbox = TelegramPersonal::ContactSyncService.new(inbox: inbox, params: params).perform
    return [nil, nil] if contact_inbox.blank?

    conversation = TelegramPersonal::ConversationSyncService.new(
      inbox: inbox,
      contact_inbox: contact_inbox,
      activity_at: Time.current,
      additional_attributes: conversation_additional_attributes
    ).perform
    [contact_inbox, conversation]
  end

  def conversation_additional_attributes
    peer_id = params[:peer_user_id] || params[:sender_id] || params[:chat_id]
    {
      chat_id: params[:chat_id].presence || peer_id.to_s.presence,
      peer_user_id: peer_id,
      username: params[:username]
    }.compact
  end

  def create_incoming_call(conversation, contact, provider_call_id)
    agent_offer = TelegramPersonal::CallBroadcaster.normalize_agent_offer(params[:agent_offer])
    meta = agent_offer.present? ? { 'agent_offer' => agent_offer, 'agent_offer_generated_at' => Time.zone.now.to_i } : {}
    stored_id = TelegramPersonal::CallBroadcaster.unique_provider_call_id(inbox.id, provider_call_id)

    Call.create!(
      provider: :telegram_personal,
      account: inbox.account,
      inbox: inbox,
      conversation: conversation,
      contact: contact,
      provider_call_id: stored_id,
      media_session_id: params[:session_id].to_s.presence,
      direction: :incoming,
      status: 'ringing',
      meta: meta
    )
  end

  def create_voice_call_message(conversation, call)
    message = TelegramPersonal::CallMessageBuilder.create!(conversation: conversation, call: call)
    call.update!(message_id: message.id)
  rescue StandardError => e
    Rails.logger.error "[TELEGRAM CALL] Failed to create voice_call message: #{e.message}"
  end

  def schedule_call_cleanup(call)
    TelegramPersonal::CallCleanupJob.set(wait: RINGING_CLEANUP_DELAY).perform_later(call.id)
  end

  def update_conversation_call_status(conversation, call_status, direction)
    attrs = (conversation.additional_attributes || {}).merge('call_status' => call_status, 'call_direction' => direction)
    conversation.update!(additional_attributes: attrs)
  end
end
