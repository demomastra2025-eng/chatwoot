class Telephony::BridgeEventsController < Telephony::BridgeBaseController
  def create
    call_session = Telephony::EventsIngestionService.new(payload: request_payload).perform

    render json: {
      status: 'ok',
      call_ref: call_session&.external_call_ref,
      conversation_id: call_session&.conversation&.display_id
    }
  rescue Telephony::Error => e
    render json: { error: e.message, code: e.code, details: e.details }, status: e.status
  end
end
