class Telephony::BridgeRoutesController < Telephony::BridgeBaseController
  def create
    render json: Telephony::InboundRoutingService.new(payload: request_payload).perform
  end
end
