class Telephony::AiVoice::EventAdapterService
  TRANSCRIPT_DELTA = 'transcript_delta'.freeze

  def initialize(payload:, headers: {})
    @payload = payload.deep_stringify_keys
    @headers = headers.deep_stringify_keys
  end

  def perform
    ensure_event_type!
    ensure_event_key!

    duplicate = processed_event?
    call_session = Telephony::EventsIngestionService.new(payload: ingestion_payload).perform
    ingest_transcript_delta! if event_type == TRANSCRIPT_DELTA && !duplicate

    response_payload(call_session, duplicate)
  end

  private

  attr_reader :payload, :headers

  def ingest_transcript_delta!
    Telephony::AiVoice::TranscriptIngestionService.new(payload: transcript_payload).perform
  end

  def ingestion_payload
    @ingestion_payload ||= begin
      normalized = payload.deep_dup
      normalized['event_key'] = event_key
      normalized['event'] = event_type
      normalized['call_ref'] = call_ref if call_ref.present?
      normalized['account_id'] = account_id if account_id.present?
      normalized['attempt'] ||= attempt if attempt.present?
      normalized['metadata'] = event_metadata
      normalized
    end
  end

  def transcript_payload
    {
      'call_ref' => call_ref,
      'account_id' => account_id,
      'conversation_id' => payload['conversation_id'],
      'final' => transcript_final?,
      'items' => transcript_items
    }.compact
  end

  def transcript_items
    items = Array.wrap(event_payload['items']).presence
    return items if items.present?

    [
      {
        'speaker' => event_payload['speaker'] || payload['speaker'],
        'text' => event_payload['text'] || payload['text'],
        'final' => transcript_final?,
        'at' => event_payload['at'] || payload['occurred_at'] || Time.current.iso8601
      }
    ]
  end

  def transcript_final?
    value = event_payload.key?('is_final') ? event_payload['is_final'] : event_payload['final']
    ActiveModel::Type::Boolean.new.cast(value || payload['final'])
  end

  def event_metadata
    base = payload['metadata'].is_a?(Hash) ? payload['metadata'].deep_dup : {}
    base['ai_voice_event'] = {
      'event_id' => event_id,
      'event_seq' => payload['event_seq'],
      'event_type' => event_type,
      'ai_session_id' => payload['ai_session_id'],
      'media_session_ref' => payload['media_session_ref'],
      'request_id' => headers['request_id'],
      'attempt' => attempt,
      'payload' => event_payload.presence
    }.compact
    base
  end

  def response_payload(call_session, duplicate)
    {
      status: duplicate ? 'duplicate' : 'ok',
      event_id: event_id,
      call_id: call_session&.id,
      call_ref: call_session&.external_call_ref,
      conversation_id: call_session&.conversation_id,
      conversation_display_id: call_session&.conversation&.display_id
    }.compact
  end

  def processed_event?
    return false if account.blank?

    account.telephony_events.exists?(event_key: event_key, status: 'processed')
  end

  def ensure_event_type!
    return if event_type.present?

    raise Telephony::Error.new(code: 'EVENT_TYPE_REQUIRED', message: 'event_type is required', status: :unprocessable_content)
  end

  def ensure_event_key!
    return if event_key.present?

    raise Telephony::Error.new(code: 'EVENT_ID_REQUIRED', message: 'event_id or X-Idempotency-Key is required', status: :unprocessable_content)
  end

  def event_type
    @event_type ||= (payload['event_type'].presence || payload['eventType'].presence || payload['event'].presence).to_s
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

  def attempt
    headers['event_attempt'].presence || payload['attempt'].presence
  end

  def call_ref
    @call_ref ||= payload['call_ref'].presence || payload['callRef'].presence || payload['provider_call_id'].presence || payload['providerCallId'].presence
  end

  def account_id
    @account_id ||= payload['account_id'].presence || payload['accountId'].presence || call_session&.account_id || conversation&.account_id
  end

  def account
    @account ||= Account.find_by(id: account_id) if account_id.present?
  end

  def call_session
    @call_session ||= Telephony::AiVoice::CallSessionResolver.new(payload: payload.merge('call_ref' => call_ref)).call_session
  end

  def conversation
    @conversation ||= ::Conversation.find_by(id: payload['conversation_id'].presence || payload['conversationId'].presence)
  end

  def event_payload
    @event_payload ||= payload['payload'].is_a?(Hash) ? payload['payload'].deep_stringify_keys : {}
  end
end
