class Internal::Voice::Ai::ControlController < Internal::Voice::Ai::BaseController
  def create
    render json: Telephony::AiVoice::ControlService.new(payload: request_payload).perform
  end
end
