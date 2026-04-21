class Telephony::BridgeRoutesController < Telephony::BridgeBaseController
  def create
    payload = request_payload
    log_telephony_debug(event: 'telephony_inbound_route_request', payload: payload)

    decision = Telephony::InboundRoutingService.new(payload: payload).perform
    log_telephony_debug(
      event: 'telephony_inbound_route_response',
      payload: payload,
      response_payload: decision,
      status: :ok
    )

    render json: decision
  rescue Telephony::Error => e
    log_telephony_debug(event: 'telephony_inbound_route_error', payload: payload || request_payload, status: e.status, error: e)
    raise
  rescue StandardError => e
    log_telephony_debug(event: 'telephony_inbound_route_error', payload: payload || request_payload, status: :internal_server_error, error: e)
    raise
  end
end
