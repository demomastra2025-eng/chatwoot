class Internal::Voice::Ai::RuntimeHandoffsController < Internal::Voice::Ai::BaseController
  def create
    render json: Telephony::AiVoice::RuntimeHandoffService.new(payload: request_payload).perform
  end
end
