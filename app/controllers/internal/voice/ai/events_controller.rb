class Internal::Voice::Ai::EventsController < Internal::Voice::Ai::BaseController
  def create
    render json: Telephony::AiVoice::EventAdapterService.new(payload: request_payload, headers: request_event_headers).perform
  end
end
