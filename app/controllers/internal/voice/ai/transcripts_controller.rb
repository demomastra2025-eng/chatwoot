class Internal::Voice::Ai::TranscriptsController < Internal::Voice::Ai::BaseController
  def create
    render json: Telephony::AiVoice::TranscriptIngestionService.new(payload: request_payload).perform
  end
end
