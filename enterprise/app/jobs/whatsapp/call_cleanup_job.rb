class Whatsapp::CallCleanupJob < ApplicationJob
  queue_as :low

  RINGING_TIMEOUT = 60.seconds
  IN_PROGRESS_TIMEOUT = 3.hours

  def perform(call_id = nil)
    if call_id.present?
      call = Call.whatsapp.find_by(id: call_id)
      expire_ringing_call(call) if call
    else
      expire_stale_ringing_calls
      expire_stale_in_progress_calls
    end
  end

  private

  def expire_stale_ringing_calls
    Call.whatsapp.ringing.where('created_at < ?', RINGING_TIMEOUT.ago).find_each do |call|
      expire_ringing_call(call)
    end
  end

  def expire_ringing_call(call)
    provider_call_id = nil
    media_session_id = nil
    transitioned = false

    call.with_lock do
      call.reload
      next unless call.ringing? && call.created_at < RINGING_TIMEOUT.ago
      next if call.incoming? && call.accepted_by_agent_id.present?

      provider_call_id = call.provider_call_id
      media_session_id = call.media_session_id
      call.update!(status: 'no_answer', end_reason: 'timeout')
      transitioned = true
    end

    return unless transitioned

    terminate_media_session(media_session_id)
    close_provider_ringing_call(call, provider_call_id)
    Whatsapp::CallMessageBuilder.update_status!(call: call, status: 'no_answer')
    update_conversation_call_status(call, 'missed')
    broadcast_call_ended(call)
  end

  def expire_stale_in_progress_calls
    Call.whatsapp.where(status: 'in_progress').where('started_at < ?', IN_PROGRESS_TIMEOUT.ago).find_each do |call|
      terminate_media_session(call.media_session_id)
      call.update!(status: 'failed', end_reason: 'timeout')
      Whatsapp::CallMessageBuilder.update_status!(call: call, status: 'failed')
      update_conversation_call_status(call, 'failed')
      broadcast_call_ended(call)
    end
  end

  def close_provider_ringing_call(call, provider_call_id)
    return if provider_call_id.blank?
    return if call.outgoing? && call.meta&.dig('outbound_prepare_pending') == true

    provider = call.inbox.channel.provider_service
    if call.incoming?
      provider.reject_call(provider_call_id)
    else
      provider.terminate_call(provider_call_id)
    end
  rescue StandardError => e
    Rails.logger.error "[WHATSAPP CALL CLEANUP] Failed to close provider call #{provider_call_id}: #{e.message}"
  end

  def terminate_media_session(media_session_id)
    return if media_session_id.blank?

    Whatsapp::MediaServerClient.new.terminate_session(media_session_id)
  rescue Whatsapp::MediaServerClient::ConnectionError, Whatsapp::MediaServerClient::SessionError => e
    Rails.logger.error "[WHATSAPP CALL CLEANUP] Failed to terminate media session #{media_session_id}: #{e.message}"
  end

  def update_conversation_call_status(call, mapped_status)
    conversation = call.conversation
    attrs = (conversation.additional_attributes || {}).merge(
      'call_status' => mapped_status,
      'call_direction' => call.direction_label
    )
    conversation.update!(additional_attributes: attrs)
  end

  def broadcast_call_ended(call)
    ActionCable.server.broadcast(
      "account_#{call.account_id}",
      {
        event: 'whatsapp_call.ended',
        data: {
          account_id: call.account_id,
          id: call.id,
          call_id: call.provider_call_id,
          status: call.status,
          duration_seconds: call.duration_seconds,
          conversation_id: call.conversation_id,
          conversation_display_id: call.conversation&.display_id
        }
      }
    )
  end
end
