class Internal::Voice::Ai::ContextController < Internal::Voice::Ai::BaseController
  def show
    render json: Telephony::AiVoice::ContextBuilder.new(params: request_payload).perform
  end
end
