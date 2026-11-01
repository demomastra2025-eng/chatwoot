class TelegramPersonal::CallCleanupJob < ApplicationJob
  queue_as :whatsapp_calls

  RINGING_TIMEOUT = 90.seconds
  RESERVATION_STALE_AFTER = 45.seconds
  IN_PROGRESS_TIMEOUT = 3.hours

  def perform(call_id = nil)
    if call_id.present?
      call = Call.telegram_personal.find_by(id: call_id)
      expire_ringing_call(call) if call
    else
      expire_stale_ringing_calls
      expire_stale_in_progress_calls
    end
  end

  private

  def expire_stale_ringing_calls
    Call.telegram_personal.ringing.where('created_at < ?', RINGING_TIMEOUT.ago).find_each do |call|
      expire_ringing_call(call)
    end
  end

  def expire_ringing_call(call)
    call_ref, transitioned = transition_ringing_to_no_answer!(call)
    return unless transitioned

    terminate_gateway_call(call, call_ref)
    TelegramPersonal::CallMessageBuilder.update_status!(call: call, status: 'no_answer')
    update_conversation_call_status(call, 'no-answer')
    TelegramPersonal::CallBroadcaster.broadcast_ended(call)
  end

  def transition_ringing_to_no_answer!(call)
    call_ref = nil
    transitioned = false
    call.with_lock do
      call.reload
      next unless call.ringing? && call.created_at < RINGING_TIMEOUT.ago
      next if fresh_incoming_reservation?(call)

      call_ref = call.media_session_id.presence || call.provider_call_id
      call.update!(status: 'no_answer', end_reason: 'timeout')
      transitioned = true
    end
    [call_ref, transitioned]
  end

  def fresh_incoming_reservation?(call)
    call.incoming? && call.accepted_by_agent_id.present? && call.updated_at > RESERVATION_STALE_AFTER.ago
  end

  def expire_stale_in_progress_calls
    stale_scope = Call.telegram_personal
                      .where(status: 'in_progress')
                      .where('COALESCE(started_at, created_at) < ?', IN_PROGRESS_TIMEOUT.ago)
    stale_scope.find_each { |call| expire_single_in_progress_call(call) }
  end

  def expire_single_in_progress_call(call)
    call_ref = nil
    transitioned = false
    call.with_lock do
      call.reload
      next unless call.in_progress?

      call_ref = call.media_session_id.presence || call.provider_call_id
      call.update!(status: 'failed', end_reason: 'timeout')
      transitioned = true
    end
    return unless transitioned

    terminate_gateway_call(call, call_ref)
    TelegramPersonal::CallMessageBuilder.update_status!(call: call, status: 'failed')
    update_conversation_call_status(call, 'failed')
    TelegramPersonal::CallBroadcaster.broadcast_ended(call)
  end

  def terminate_gateway_call(call, call_ref)
    return if call_ref.blank? || call.inbox&.channel.blank?

    client = TelegramPersonal::GatewayClient.new(channel: call.inbox.channel)
    if call.incoming?
      client.reject_call!(call_ref: call_ref, reason: 'missed')
    else
      client.terminate_call!(call_ref: call_ref)
    end
  rescue StandardError => e
    Rails.logger.warn "[TELEGRAM CALL CLEANUP] Failed to close gateway call #{call_ref}: #{e.message}"
  end

  def update_conversation_call_status(call, mapped_status)
    conversation = call.conversation
    attrs = (conversation.additional_attributes || {}).merge(
      'call_status' => mapped_status,
      'call_direction' => call.direction_label
    )
    conversation.update!(additional_attributes: attrs)
  end
end
