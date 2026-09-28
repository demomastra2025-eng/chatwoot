require 'digest'

class MediaServer::CallbacksController < ApplicationController
  before_action :validate_media_server_token
  before_action :ensure_account_id!

  def agent_disconnected
    call = find_call_by_session
    return head :not_found unless call
    return head :ok if call.terminal?

    broadcast_agent_disconnected(call)
    head :ok
  end

  def recording_ready
    return recording_bundle_ready if params.key?(:recording_manifest_version)

    call = find_call_by_session
    return head :not_found unless call

    Whatsapp::CallRecordingFetchJob.perform_later(call.id) if mark_recording_ready!(call)
    head :ok
  end

  def session_terminated
    call = find_call_by_session
    return head :not_found unless call

    final_status = nil
    duration_seconds = normalized_duration_seconds
    transitioned = false
    rtp_gate = normalized_rtp_gate
    media_gate_failed = rtp_gate[:present] && !rtp_gate[:media_ready]
    reason = media_gate_failed ? 'bidirectional_rtp_missing' : (params[:reason].presence || 'media_server')

    call.with_lock do
      call.reload
      unless call.terminal?
        was_answered = call.in_progress? || duration_seconds.to_i.positive?
        final_status = if media_gate_failed
                         'failed'
                       else
                         (was_answered ? 'completed' : 'failed')
                       end
        attrs = { status: final_status, end_reason: reason }
        attrs[:duration_seconds] = duration_seconds if duration_seconds
        attrs[:media_session_id] = params[:session_id] if call.media_session_id.blank? && params[:session_id].present?
        attrs[:accepted_by_agent_id] = nil if final_status == 'failed'
        attrs[:meta] = with_media_server_termination_stats(call, rtp_gate) if rtp_gate[:present]
        call.update!(attrs)
        transitioned = true
      end
    end

    if transitioned
      agent = call.accepted_by_agent if call.accepted_by_agent_id.present?
      Whatsapp::CallMessageBuilder.update_status!(call: call, status: final_status, agent: agent, duration_seconds: duration_seconds)
      mapped = Whatsapp::CallMessageBuilder::CALL_TO_VOICE_STATUS[final_status] || final_status
      update_conversation_call_status(call, mapped)
      broadcast_call_ended(call, final_status)
      terminate_on_provider(call)
      Whatsapp::CallRecordingFetchJob.perform_later(call.id) if call.media_session_id.present?
    end

    head :ok
  rescue StandardError => e
    Rails.logger.error "[MEDIA SERVER] Failed to process session_terminated callback: #{e.message}"
    head :ok unless performed?
  end

  def error
    call = find_call_by_session
    return head :not_found unless call

    error_code = params[:code].to_s
    error_message = params[:error].to_s
    error_reason = [error_code.presence, error_message.presence].compact.join(': ')
    error_reason = 'media_server_error' if error_reason.blank?

    begin
      call.update!(end_reason: error_reason) unless call.terminal?
    rescue StandardError => e
      Rails.logger.error "[MEDIA SERVER] Failed to record error reason for call #{call.provider_call_id}: #{e.message}"
    end

    Rails.logger.error "[MEDIA SERVER] callback error for call #{call.provider_call_id}: #{error_reason}"
    head :ok
  end

  private

  def recording_bundle_ready
    return head :unprocessable_entity unless params[:recording_manifest_version].to_s == '1'

    return head :bad_request unless valid_recording_bundle_signal?

    call = Call.find_by(account_id: params[:account_id], provider_call_id: params[:call_id])
    return head :not_found unless call

    status = bind_recording_bundle_signal(call)
    return head :conflict if status == :conflict

    Whatsapp::CallRecordingFetchJob.perform_later(call.id) if status == :enqueue
    head :ok
  end

  def valid_recording_bundle_signal?
    params[:recording_manifest_sha256].to_s.match?(/\A[0-9a-f]{64}\z/) &&
      params[:session_id].to_s.match?(/\A[A-Za-z0-9_-]{1,128}\z/) && params[:call_id].present?
  end

  def bind_recording_bundle_signal(call)
    digest = params[:recording_manifest_sha256].to_s
    call.with_lock do
      call.reload
      bundle = (call.meta || {})['recording_bundle'] || {}
      status = recording_bundle_signal_status(call, bundle, digest)
      if status == :enqueue
        meta = (call.meta || {}).deep_dup
        meta['recording_bundle'] = bundle.merge('version' => 1, 'expected_sha256' => digest)
        call.update!(media_session_id: params[:session_id].to_s, meta: meta)
      end
      status
    end
  end

  def recording_bundle_signal_status(call, bundle, digest)
    return :conflict if recording_bundle_scope_conflict?(call)
    return :conflict if bundle['completed_sha256'].present? && bundle['completed_sha256'] != digest
    return :complete if bundle['completed_sha256'] == digest && call.recording_manifest.attached?

    :enqueue
  end

  def recording_bundle_scope_conflict?(call)
    !recording_bundle_call_matches?(call) || (call.media_session_id.present? && call.media_session_id != params[:session_id].to_s)
  end

  def recording_bundle_call_matches?(call)
    call.account_id.to_s == params[:account_id].to_s && call.provider_call_id == params[:call_id].to_s
  end

  def validate_media_server_token
    expected = ENV.fetch('MEDIA_SERVER_AUTH_TOKEN', '').to_s
    token = request.authorization.to_s[/\ABearer\s+(.+)\z/i, 1].to_s

    return head :unauthorized if expected.blank? || token.blank?

    expected_digest = Digest::SHA256.hexdigest(expected)
    token_digest = Digest::SHA256.hexdigest(token)
    head :unauthorized unless ActiveSupport::SecurityUtils.secure_compare(token_digest, expected_digest)
  end

  def ensure_account_id!
    head :bad_request if params[:account_id].blank?
  end

  def find_call_by_session
    account_id = params[:account_id]
    session_id = params[:session_id].presence
    call = Call.find_by(media_session_id: session_id, account_id: account_id) if session_id
    return call if call

    provider_call_id = params[:call_id].presence
    return if provider_call_id.blank?

    Call.find_by(provider_call_id: provider_call_id, account_id: account_id)
  end

  def mark_recording_ready!(call)
    enqueue_fetch = false

    call.with_lock do
      call.reload
      unless call.recording.attached? || media_server_callback_marked?(call, 'recording_ready_at')
        attrs = { meta: with_media_server_callback_mark(call, 'recording_ready_at') }
        attrs[:media_session_id] = params[:session_id] if call.media_session_id.blank? && params[:session_id].present?
        call.update!(attrs)
        enqueue_fetch = true
      end
    end

    enqueue_fetch
  end

  def media_server_callback_marked?(call, key)
    (call.meta || {}).dig('media_server', 'callbacks', key).present?
  end

  def with_media_server_callback_mark(call, key)
    meta = (call.meta || {}).deep_dup
    meta['media_server'] ||= {}
    meta['media_server']['callbacks'] ||= {}
    meta['media_server']['callbacks'][key] = Time.current.iso8601
    meta['media_server']['callbacks']['recording_file_size_bytes'] = params[:file_size_bytes].to_i if params[:file_size_bytes].present?
    meta
  end

  def normalized_duration_seconds
    return if params[:duration_seconds].blank?

    seconds = params[:duration_seconds].to_i
    seconds.negative? ? 0 : seconds
  end

  def normalized_rtp_gate
    meta_to_agent = integer_param(:meta_to_agent_packets)
    agent_to_meta = integer_param(:agent_to_meta_packets)
    media_ready_present = params.key?(:media_ready)
    counters_present = !meta_to_agent.nil? || !agent_to_meta.nil?
    present = media_ready_present || counters_present

    declared_media_ready = media_ready_present ? ActiveModel::Type::Boolean.new.cast(params[:media_ready]) : true
    counters_ready = counters_present ? (meta_to_agent.to_i.positive? && agent_to_meta.to_i.positive?) : true
    media_ready = declared_media_ready && counters_ready

    {
      present: present,
      media_ready: media_ready,
      meta_to_agent_packets: meta_to_agent,
      agent_to_meta_packets: agent_to_meta
    }
  end

  def integer_param(key)
    return unless params.key?(key)

    params[key].to_i
  end

  def with_media_server_termination_stats(call, rtp_gate)
    meta = (call.meta || {}).deep_dup
    meta['media_server'] ||= {}
    meta['media_server']['callbacks'] ||= {}
    meta['media_server']['callbacks']['session_terminated_at'] = Time.current.iso8601
    meta['media_server']['callbacks']['media_ready'] = rtp_gate[:media_ready]
    meta['media_server']['callbacks']['meta_to_agent_packets'] = rtp_gate[:meta_to_agent_packets] unless rtp_gate[:meta_to_agent_packets].nil?
    meta['media_server']['callbacks']['agent_to_meta_packets'] = rtp_gate[:agent_to_meta_packets] unless rtp_gate[:agent_to_meta_packets].nil?
    meta
  end

  def terminate_on_provider(call)
    call.inbox.channel.provider_service.terminate_call(call.provider_call_id)
  rescue StandardError => e
    Rails.logger.error "[MEDIA SERVER] Failed to terminate provider call #{call.provider_call_id}: #{e.message}"
  end

  def update_conversation_call_status(call, mapped_status)
    conversation = call.conversation
    attrs = (conversation.additional_attributes || {}).merge('call_status' => mapped_status)
    conversation.update!(additional_attributes: attrs)
  end

  def broadcast_agent_disconnected(call)
    ActionCable.server.broadcast(
      "account_#{call.account_id}",
      {
        event: 'whatsapp_call.agent_disconnected',
        data: {
          account_id: call.account_id,
          id: call.id,
          call_id: call.provider_call_id,
          conversation_id: call.conversation_id,
          reason: params[:reason]
        }
      }
    )
  end

  def broadcast_call_ended(call, final_status)
    ActionCable.server.broadcast(
      "account_#{call.account_id}",
      {
        event: 'whatsapp_call.ended',
        data: {
          account_id: call.account_id,
          id: call.id,
          call_id: call.provider_call_id,
          status: final_status,
          duration_seconds: call.duration_seconds,
          conversation_id: call.conversation_id
        }
      }
    )
  end
end
