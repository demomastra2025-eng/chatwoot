class Telephony::AiVoice::FinalizationService
  ALLOWED_FINAL_STATUSES = %w[
    completed transferred failed caller_hung_up operator_unavailable rejected cancelled timeout
  ].freeze

  STATUS_MAP = {
    'completed' => 'completed',
    'transferred' => 'completed',
    'failed' => 'failed',
    'caller_hung_up' => 'cancelled',
    'operator_unavailable' => 'no_answer',
    'rejected' => 'rejected',
    'cancelled' => 'cancelled',
    'timeout' => 'no_answer'
  }.freeze

  def initialize(payload:, headers: {})
    @payload = payload.deep_stringify_keys
    @headers = headers.deep_stringify_keys
  end

  def perform
    ensure_event_key!
    ensure_status!
    ensure_call_session!

    already_finalized = false
    call_session.with_lock do
      call_session.reload
      already_finalized = finalized_metadata.present?
      already_finalized ? record_finalize_conflict! : apply_finalize!
    end

    persist_finalize_event!
    ingest_final_transcript! unless already_finalized
    run_post_call_captain_features!
    sync_conversation!(already_finalized: already_finalized)
    response_payload(already_finalized: already_finalized, conflict: already_finalized && finalize_conflict?)
  end

  private

  attr_reader :payload, :headers

  def apply_finalize!
    metadata = (call_session.metadata || {}).deep_dup
    ai_voice = metadata['ai_voice'] ||= {}
    ai_voice['finalize'] = finalize_metadata
    ai_voice['transfer_result'] = transfer_result if transfer_result.present?
    ai_voice['final_transcript'] = final_transcript if final_transcript.present?
    ai_voice['last_error'] = error_payload if error_payload.present?
    ai_voice['recording'] = recording_metadata if recording_metadata.present?

    attrs = {
      status: canonical_status,
      ended_at: ended_at || call_session.ended_at || Time.current,
      ended_by: ended_by || call_session.ended_by,
      end_reason: reason || call_session.end_reason || final_status,
      metadata: metadata,
      last_event_at: [call_session.last_event_at, occurred_at].compact.max
    }
    attrs[:started_at] = started_at if started_at.present? && call_session.started_at.blank?
    attrs[:duration_seconds] = duration_seconds if duration_seconds.present?
    attrs[:summary] = summary if summary.present?
    attrs[:recording_ref] = recording_ref if recording_ref.present?
    attrs[:transcript_ref] = transcript_ref if transcript_ref.present?

    call_session.update!(attrs)
  end

  def record_finalize_conflict!
    return unless finalize_conflict?

    metadata = (call_session.metadata || {}).deep_dup
    ai_voice = metadata['ai_voice'] ||= {}
    conflicts = ai_voice['finalize_conflicts'] ||= []
    conflicts << finalize_metadata.merge('stored_finalize' => finalized_metadata)
    ai_voice['finalize_conflicts'] = conflicts.last(10)
    call_session.update!(metadata: metadata)
  end

  def persist_finalize_event!
    event = account.telephony_events.find_by(event_key: event_key)
    event ||= account.telephony_events.create!(
      event_key: event_key,
      event_type: 'finalize',
      payload: event_payload,
      call_session: call_session
    )
    return if event.processed?

    event.update!(
      event_type: 'finalize',
      payload: event_payload,
      call_session: call_session,
      status: 'processed',
      processed_at: Time.current,
      error_message: nil
    )
  rescue ActiveRecord::RecordNotUnique
    retry
  end

  def ingest_final_transcript!
    return if final_transcript.blank?

    Telephony::AiVoice::TranscriptIngestionService.new(
      payload: {
        'call_ref' => call_ref,
        'account_id' => account.id,
        'conversation_id' => call_session.conversation_id,
        'final' => true,
        'items' => final_transcript.map { |item| item.merge('final' => true) }
      }
    ).perform
  end

  def run_post_call_captain_features!
    Telephony::AiVoice::PostCallCaptainFeaturesService.new(call_session: call_session).perform
  end

  def sync_conversation!(already_finalized: false)
    return if conversation.blank?

    attrs = (conversation.additional_attributes || {}).deep_dup
    attrs['telephony_provider'] = call_session.provider
    attrs['recording_ref'] = call_session.recording_ref if call_session.recording_ref.present?
    attrs['transcript_ref'] = call_session.transcript_ref if call_session.transcript_ref.present?
    attrs['summary'] = call_session.summary if call_session.summary.present?
    attrs['ai_voice_final_status'] = conversation_final_status(already_finalized: already_finalized)
    conversation.update!(additional_attributes: attrs, last_activity_at: Time.current)
  end

  def conversation_final_status(already_finalized:)
    return final_status unless already_finalized

    finalized_metadata&.dig('status').presence || final_status
  end

  def response_payload(already_finalized:, conflict: false)
    {
      status: 'ok',
      ok: true,
      event_id: event_id,
      call_id: call_session.id,
      call_ref: call_session.external_call_ref,
      conversation_id: call_session.conversation_id,
      conversation_display_id: conversation&.display_id,
      already_finalized: already_finalized,
      conflict: conflict,
      stored_status: call_session.status
    }.compact
  end

  def finalize_metadata
    {
      'event_id' => event_id,
      'event_seq' => payload['event_seq'],
      'provider_call_id' => provider_call_id,
      'bridge_call_ref' => bridge_call_ref,
      'runtime_call_ref' => runtime_call_ref,
      'ai_runtime_call_ref' => ai_runtime_call_ref,
      'provider_session_id' => payload['provider_session_id'].presence || payload['providerSessionId'].presence,
      'ai_session_id' => payload['ai_session_id'],
      'media_session_ref' => media_session_ref,
      'stream_ref' => stream_ref,
      'recording_status' => recording_status,
      'degraded' => degraded,
      'missing_direction' => missing_direction,
      'status' => final_status,
      'stored_status' => canonical_status,
      'reason' => reason,
      'started_at' => started_at&.iso8601,
      'ended_at' => (ended_at || Time.current)&.iso8601,
      'duration_ms' => duration_ms,
      'request_id' => headers['request_id'],
      'attempt' => attempt,
      'payload' => payload.except('controller', 'action')
    }.compact
  end

  def finalized_metadata
    call_session.metadata&.dig('ai_voice', 'finalize')
  end

  def finalize_conflict?
    finalized_metadata['status'] != final_status || finalized_metadata['reason'] != reason
  end

  def event_payload
    @event_payload ||= payload.merge(
      'event_key' => event_key,
      'event' => 'finalize',
      'call_ref' => call_ref,
      'account_id' => account.id,
      'status' => canonical_status,
      'duration' => duration_seconds
    ).compact
  end

  def ensure_event_key!
    return if event_key.present?

    raise Telephony::Error.new(code: 'EVENT_ID_REQUIRED', message: 'event_id or X-Idempotency-Key is required', status: :unprocessable_content)
  end

  def ensure_status!
    return if ALLOWED_FINAL_STATUSES.include?(final_status)

    raise Telephony::Error.new(code: 'FINAL_STATUS_NOT_ALLOWED', message: 'final status is not allowed', status: :unprocessable_content)
  end

  def ensure_call_session!
    return if call_session.present?

    raise Telephony::Error.new(code: 'CALL_SESSION_NOT_FOUND', message: 'Unable to resolve call session for finalize', status: :not_found)
  end

  def event_key
    @event_key ||= headers['idempotency_key'].presence || payload['idempotency_key'].presence || payload['idempotencyKey'].presence ||
                   payload['event_key'].presence || payload['eventKey'].presence || raw_event_id
  end

  def event_id
    @event_id ||= raw_event_id || event_key
  end

  def raw_event_id
    @raw_event_id ||= headers['event_id'].presence || payload['event_id'].presence || payload['eventId'].presence
  end

  def final_status
    @final_status ||= payload['status'].to_s
  end

  def canonical_status
    STATUS_MAP[final_status]
  end

  def call_ref
    @call_ref ||= bridge_call_ref || payload['call_ref'].presence || payload['callRef'].presence || provider_call_id
  end

  def provider_call_id
    payload['provider_call_id'].presence || payload['providerCallId'].presence
  end

  def bridge_call_ref
    payload['bridge_call_ref'].presence ||
      payload['bridgeCallRef'].presence ||
      payload['parent_call_ref'].presence ||
      payload['parentCallRef'].presence
  end

  def runtime_call_ref
    payload['runtime_call_ref'].presence ||
      payload['runtimeCallRef'].presence ||
      payload['child_call_ref'].presence ||
      payload['childCallRef'].presence ||
      ai_runtime_call_ref
  end

  def ai_runtime_call_ref
    payload['ai_runtime_call_ref'].presence || payload['aiRuntimeCallRef'].presence || call_ref
  end

  def media_session_ref
    payload['media_session_ref'].presence || payload['mediaSessionRef'].presence
  end

  def stream_ref
    payload['stream_ref'].presence || payload['streamRef'].presence
  end

  def call_session
    @call_session ||= Telephony::AiVoice::CallSessionResolver.new(payload: payload.merge('call_ref' => call_ref)).call_session
  end

  def account
    call_session.account
  end

  def conversation
    call_session.conversation
  end

  def transfer_result
    payload['transfer_result'].is_a?(Hash) ? payload['transfer_result'].deep_stringify_keys : nil
  end

  def final_transcript
    Array.wrap(payload['final_transcript']).filter_map do |item|
      item = item.deep_stringify_keys
      text = item['text'].to_s.strip
      next if text.blank?

      {
        'speaker' => item['speaker'],
        'text' => text,
        'at' => item['at'].presence || Time.current.iso8601
      }
    end
  end

  def error_payload
    return if payload['error_code'].blank? && payload['error_message'].blank?

    {
      'error_code' => payload['error_code'],
      'error_message' => payload['error_message']
    }.compact
  end

  def recording_metadata
    metadata = {
      'recording_ref' => recording_ref,
      'recording_status' => recording_status,
      'degraded' => degraded,
      'missing_direction' => missing_direction,
      'media_session_ref' => media_session_ref,
      'stream_ref' => stream_ref
    }.compact
    metadata.presence
  end

  def recording_status
    payload['recording_status'].presence || payload['recordingStatus'].presence
  end

  def degraded
    value = payload.key?('degraded') ? payload['degraded'] : payload['recording_degraded']
    return if value.nil?

    ActiveModel::Type::Boolean.new.cast(value)
  end

  def missing_direction
    payload['missing_direction'].presence || payload['missingDirection'].presence
  end

  def recording_ref
    payload['recording_ref'].presence || payload['recordingRef'].presence || payload['recording_url'].presence || payload['recordingUrl'].presence
  end

  def transcript_ref
    payload['transcript_ref'].presence || payload['transcriptRef'].presence || ("ai_voice_transcript:#{call_ref}" if final_transcript.present?)
  end

  def summary
    payload['summary'].presence
  end

  def reason
    payload['reason'].presence || payload['end_reason'].presence || payload['endReason'].presence
  end

  def ended_by
    payload['ended_by'].presence || payload['endedBy'].presence || default_ended_by
  end

  def default_ended_by
    return 'caller' if final_status == 'caller_hung_up'
    return 'operator' if final_status == 'transferred'

    'ai'
  end

  def started_at
    parse_time(payload['started_at'] || payload['startedAt'])
  end

  def ended_at
    parse_time(payload['ended_at'] || payload['endedAt'] || payload['occurred_at'] || payload['occurredAt'])
  end

  def occurred_at
    ended_at || Time.current
  end

  def duration_seconds
    return if duration_ms.blank?

    (duration_ms.to_f / 1000).ceil
  end

  def duration_ms
    value = payload['duration_ms'].presence || payload['durationMs'].presence
    value.to_i if value.present?
  end

  def attempt
    headers['event_attempt'].presence || payload['attempt'].presence
  end

  def parse_time(value)
    return if value.blank?

    Time.zone.parse(value.to_s)
  rescue ArgumentError
    nil
  end
end
