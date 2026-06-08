class Telephony::BridgeEventsController < Telephony::BridgeBaseController
  def create
    payload = request_payload
    log_telephony_debug(event: 'telephony_inbound_event_request', payload: payload)

    Telephony::InboundRouteLifecycleJob.perform_later(payload)
    response_payload = accepted_response_payload(payload)
    log_telephony_debug(
      event: 'telephony_inbound_event_response',
      payload: payload,
      response_payload: response_payload,
      status: :accepted
    )

    render json: response_payload, status: :accepted
  rescue ActiveJob::EnqueueError, Redis::BaseError, RedisClient::Error => e
    log_telephony_debug(
      event: 'telephony_inbound_event_queue_fallback',
      payload: payload || request_payload,
      status: :ok,
      error: e
    )
    render_sync_fallback(payload || request_payload)
  rescue Telephony::Error => e
    error_payload = { error: e.message, code: e.code, details: e.details }
    log_telephony_debug(
      event: 'telephony_inbound_event_error',
      payload: payload || request_payload,
      response_payload: error_payload,
      status: e.status,
      error: e
    )
    render json: error_payload, status: e.status
  rescue StandardError => e
    log_telephony_debug(
      event: 'telephony_inbound_event_error',
      payload: payload || request_payload,
      status: :internal_server_error,
      error: e
    )
    raise
  end

  private

  def render_sync_fallback(payload)
    call_session = Telephony::EventsIngestionService.new(payload: payload).perform
    response_payload = {
      status: 'ok',
      mode: 'sync_fallback',
      call_ref: call_session&.external_call_ref,
      conversation_id: call_session&.conversation&.display_id
    }
    log_telephony_debug(
      event: 'telephony_inbound_event_response',
      payload: payload,
      response_payload: response_payload,
      status: :ok
    )
    render json: response_payload
  end

  def accepted_response_payload(payload)
    {
      status: 'accepted',
      mode: 'async',
      call_ref: payload_value(payload, 'call_ref', 'callRef', 'call_sid', 'callSid'),
      event_key: payload_value(payload, 'event_key', 'eventKey', 'idempotency_key', 'idempotencyKey')
    }.compact
  end

  def payload_value(payload, *keys)
    payload = payload.to_h
    keys.each do |key|
      value = payload[key] || payload[key.to_s]
      return value if value.present?
    end
    nil
  end
end
