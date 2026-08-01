class Telephony::BridgeRoutesController < Telephony::BridgeBaseController
  def create
    payload = request_payload
    log_telephony_debug(event: 'telephony_inbound_route_request', payload: payload)

    decision = Telephony::InboundRoutingService.new(
      payload: payload,
      runtime_capabilities: request.headers['X-OneLink-Voice-Capabilities'].to_s.split(',')
    ).perform
    log_telephony_debug(
      event: 'telephony_inbound_route_response',
      payload: payload,
      response_payload: decision,
      status: :ok
    )

    render json: decision
  rescue Telephony::Error => e
    error_decision = reject_decision(reason: e.code.presence || 'route_error', message: e.message)
    log_telephony_debug(
      event: 'telephony_inbound_route_error',
      payload: payload || request_payload,
      response_payload: error_decision,
      status: :ok,
      error: e
    )
    render json: error_decision
  rescue StandardError => e
    error_decision = reject_decision(reason: 'route_error')
    log_telephony_debug(
      event: 'telephony_inbound_route_error',
      payload: payload || request_payload,
      response_payload: error_decision,
      status: :ok,
      error: e
    )
    render json: error_decision
  end

  private

  def reject_decision(reason:, message: nil)
    {
      action: 'reject',
      message: message.presence || Telephony::InboundRoutingService::DEFAULT_REJECT_MESSAGE,
      reason: reason
    }
  end
end
