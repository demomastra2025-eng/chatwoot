class Internal::Voice::Ai::FinalizationsController < Internal::Voice::Ai::BaseController
  def create
    render json: Telephony::AiVoice::FinalizationService.new(payload: request_payload, headers: request_event_headers).perform
  end
end
