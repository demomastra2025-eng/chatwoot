class TelegramPersonal::CallService
  pattr_initialize [:call!, :agent!]

  attr_reader :agent_offer

  def accept
    reserve_acceptance!
    accept_on_gateway_and_commit!
    finalize_accepted_call!
    call
  end

  def reject
    call_ref, transitioned = mark_call_rejected!
    if transitioned
      notify_gateway(:reject_call!, call_ref)
      after_status_transition(status: 'failed')
    end
    call
  end

  def terminate
    result = mark_call_terminated!
    if result[:transitioned]
      notify_gateway(:terminate_call!, result[:call_ref])
      after_status_transition(status: result[:status], duration_seconds: call.duration_seconds)
      enqueue_recording_if_completed(result)
    end
    call
  end

  private

  def accept_on_gateway_and_commit!
    gateway_accepted = false
    response = gateway_client.accept_call!(call_ref: gateway_call_ref)
    gateway_accepted = true
    @agent_offer = TelegramPersonal::CallBroadcaster.normalize_agent_offer(response[:agent_offer]) || existing_agent_offer
    commit_accepted_call!(response[:session_id])
  rescue StandardError
    notify_gateway(:terminate_call!, gateway_call_ref) if gateway_accepted
    release_acceptance_reservation!
    raise
  end

  def commit_accepted_call!(session_id)
    call.with_lock do
      call.reload
      ensure_ringing!
      ensure_reserved_by_current_agent!
      merged_meta = TelegramPersonal::CallBroadcaster.merged_agent_offer_meta(call.meta, agent.id, @agent_offer)
      call.update!(
        status: 'in_progress', started_at: Time.current,
        media_session_id: session_id.presence || call.media_session_id, meta: merged_meta
      )
    end
  end

  def finalize_accepted_call!
    TelegramPersonal::CallMessageBuilder.update_status!(call: call, status: 'in_progress', agent: agent)
    update_conversation_call_status('in-progress')
    TelegramPersonal::CallBroadcaster.broadcast_agent_offer(call, agent, @agent_offer)
    TelegramPersonal::CallBroadcaster.broadcast_accepted(call, agent)
  end

  def mark_call_rejected!
    call_ref = nil
    transitioned = false
    call.with_lock do
      call.reload
      next if call.terminal? || call.in_progress?

      ensure_agent_owns_call!
      call_ref = gateway_call_ref
      call.update!(status: 'failed', end_reason: 'rejected')
      transitioned = true
    end
    [call_ref, transitioned]
  end

  def mark_call_terminated!
    result = { transitioned: false, call_ref: nil, media_session_id: nil, status: 'completed' }
    call.with_lock do
      call.reload
      next if call.terminal?

      ensure_agent_owns_call!
      result = apply_terminate_update!
    end
    result
  end

  def apply_terminate_update!
    prepared_outbound = prepared_outbound_pending?
    unanswered_cancel = !prepared_outbound && !call.in_progress? && call.started_at.blank?
    target_status = terminate_target_status(prepared_outbound, unanswered_cancel)
    call_ref = gateway_call_ref
    media_session_id = call.media_session_id
    call.update!(
      status: target_status, end_reason: terminate_end_reason(prepared_outbound, unanswered_cancel),
      duration_seconds: compute_duration_seconds, meta: terminate_meta(prepared_outbound)
    )
    { transitioned: true, call_ref: call_ref, media_session_id: media_session_id, status: target_status }
  end

  def terminate_target_status(prepared_outbound, unanswered_cancel)
    return 'failed' if prepared_outbound
    return 'no_answer' if unanswered_cancel

    'completed'
  end

  def terminate_end_reason(prepared_outbound, unanswered_cancel)
    return 'agent_setup_failed' if prepared_outbound
    return 'cancelled' if unanswered_cancel

    call.end_reason.presence || 'agent_terminated'
  end

  def terminate_meta(prepared_outbound)
    return call.meta unless prepared_outbound

    (call.meta || {}).merge('outbound_prepare_pending' => false, 'outbound_dialing' => false)
  end

  def enqueue_recording_if_completed(result)
    return unless result[:media_session_id].present? && result[:status] == 'completed'

    TelegramPersonal::CallRecordingFetchJob.perform_later(call.id)
  end

  def gateway_client
    @gateway_client ||= TelegramPersonal::GatewayClient.new(channel: call.inbox.channel)
  end

  def gateway_call_ref
    call.media_session_id.presence || call.provider_call_id
  end

  def compute_duration_seconds
    return call.duration_seconds if call.duration_seconds.present?
    return nil if call.started_at.blank?

    [(Time.current - call.started_at).to_i, 0].max
  end

  def prepared_outbound_pending?
    call.outgoing? && call.meta&.dig('outbound_prepare_pending') == true
  end

  def existing_agent_offer
    TelegramPersonal::CallBroadcaster.normalize_agent_offer((call.meta || {})['agent_offer'])
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

  def notify_gateway(method_name, call_ref)
    return if call_ref.blank?

    gateway_client.public_send(method_name, call_ref: call_ref)
  rescue StandardError => e
    Rails.logger.warn "[TELEGRAM CALL] Failed #{method_name} for call #{call_ref} on gateway: #{e.message}"
  end

  def after_status_transition(status:, agent: nil, duration_seconds: nil)
    TelegramPersonal::CallMessageBuilder.update_status!(
      call: call, status: status, agent: agent, duration_seconds: duration_seconds
    )
    update_conversation_call_status(TelegramPersonal::CallMessageBuilder::CALL_TO_VOICE_STATUS[status] || status)
    TelegramPersonal::CallBroadcaster.broadcast_ended(call)
  end

  def ensure_ringing!
    raise TelegramPersonal::CallErrors::NotRinging, 'Call is not in ringing state' unless call.ringing?
  end

  def ensure_reserved_by_current_agent!
    return if call.accepted_by_agent_id == agent.id

    raise TelegramPersonal::CallErrors::AlreadyAccepted, 'Call already accepted by another agent'
  end

  def ensure_agent_owns_call!
    owner_id = call.accepted_by_agent_id
    return if agent.blank? || owner_id.blank? || owner_id == agent.id

    raise TelegramPersonal::CallErrors::NotCallOwner, 'Call accepted by another agent'
  end

  def ensure_not_already_taken!
    already_reserved_by_other_agent = call.accepted_by_agent_id.present? && call.accepted_by_agent_id != agent.id
    return unless call.in_progress? || already_reserved_by_other_agent

    raise TelegramPersonal::CallErrors::AlreadyAccepted, 'Call already accepted by another agent'
  end

  def update_conversation_call_status(mapped_status)
    conversation = call.conversation
    conversation.update!(additional_attributes: (conversation.additional_attributes || {}).merge('call_status' => mapped_status))
  end
end
