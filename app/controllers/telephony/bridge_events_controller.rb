class Telephony::BridgeEventsController < Telephony::BridgeBaseController
  def create
    payload = request_payload
    log_telephony_debug(event: 'telephony_inbound_event_request', payload: payload)

    call_session = Telephony::EventsIngestionService.new(payload: payload).perform

    response_payload = {
      status: 'ok',
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
end
