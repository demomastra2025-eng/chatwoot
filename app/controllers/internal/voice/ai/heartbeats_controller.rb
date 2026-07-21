class Internal::Voice::Ai::HeartbeatsController < Internal::Voice::Ai::BaseController
  def create
    render json: Telephony::AiVoice::HeartbeatService.new(payload: request_payload).perform
  end
end
